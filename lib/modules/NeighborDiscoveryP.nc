#include "../../includes/packet.h"
#include "../../includes/neighbor.h"
#include "../../includes/channels.h"

// All storage is static because the target platform does not dynamically
// allocate memory. Probe cadence is intentionally slow; random offsets reduce
// the chance that nearby motes transmit their periodic broadcasts together.
#define MAX_NEIGHBORS 20
#define NEIGHBOR_PROBE_INTERVAL 30000
#define NEIGHBOR_PROBE_JITTER 5000
#define MAX_MISSED_NEIGHBOR_PROBES 5

typedef struct {
   neighborInfo info;
   // Cumulative successful radio probes and matching replies provide the
   // displayed link-quality percentage. missedProbes is consecutive loss,
   // used separately to decide whether a neighbor is currently active.
   uint16_t probesSent;
   uint16_t repliesReceived;
   uint8_t missedProbes;
} neighborRecord;

module NeighborDiscoveryP{
   provides interface NeighborDiscovery;
   uses interface Boot;
   uses interface SplitControl as AMControl;
   uses interface Flooding;
   uses interface SimpleSend as Sender;
   uses interface Timer<TMilli> as probeTimer;
   uses interface Random;
}

implementation{
   // The public table stores only address/quality/active; counters are private
   // bookkeeping for quality and liveness decisions.
   neighborRecord neighbors[MAX_NEIGHBORS];
   uint8_t neighborCount = 0;
   uint16_t nextProbeSeq = 1;
   // Replies echo the originating probe sequence. Only the most recently
   // transmitted probe is considered current; delayed replies are ignored.
   uint16_t currentProbeSeq = 0;
   bool hasCurrentProbe = FALSE;
   uint8_t emptyPayload[PACKET_MAX_PAYLOAD_SIZE] = {0};

   uint8_t findNeighbor(uint16_t address){
      uint8_t i;
      for(i = 0; i < neighborCount; i++){
         if(neighbors[i].info.address == address){
            return i;
         }
      }
      return MAX_NEIGHBORS;
   }

   // Ensure every directly observed peer has a table entry. Return the
   // sentinel MAX_NEIGHBORS if the fixed-capacity table is full.
   uint8_t ensureNeighbor(uint16_t address){
      uint8_t slot = findNeighbor(address);
      if(slot != MAX_NEIGHBORS){
         return slot;
      }
      if(neighborCount >= MAX_NEIGHBORS){
         dbg(NEIGHBOR_CHANNEL, "Neighbor table full; cannot add node %hu\n", address);
         return MAX_NEIGHBORS;
      }

      slot = neighborCount++;
      neighbors[slot].info.address = address;
      neighbors[slot].info.quality = 0;
      neighbors[slot].info.active = FALSE;
      neighbors[slot].probesSent = 0;
      neighbors[slot].repliesReceived = 0;
      neighbors[slot].missedProbes = 0;
      return slot;
   }

   void updateQuality(uint8_t slot){
      uint32_t quality;
      if(neighbors[slot].probesSent == 0){
         neighbors[slot].info.quality = 0;
         return;
      }

      // Integer arithmetic avoids floating-point work on motes. Replies may
      // race with a probe's sendDone bookkeeping, so clamp to 100 percent.
      quality = ((uint32_t) neighbors[slot].repliesReceived * 100) /
                neighbors[slot].probesSent;
      if(quality > 100){
         quality = 100;
      }
      neighbors[slot].info.quality = quality;
   }

   void scheduleNextProbe(){
      // Re-arm after each attempt rather than using a periodic timer so every
      // interval can have independent jitter.
      uint16_t delay = NEIGHBOR_PROBE_INTERVAL - NEIGHBOR_PROBE_JITTER +
                      (call Random.rand16() %
                       ((2 * NEIGHBOR_PROBE_JITTER) + 1));
      call probeTimer.startOneShot(delay);
   }

   command uint8_t NeighborDiscovery.getNeighborCount(){
      return neighborCount;
   }

   command bool NeighborDiscovery.getNeighbor(uint8_t slot, neighborInfo *info){
      // The app and other components can query a snapshot without accessing
      // discovery's private counters or modifying its table.
      if(slot >= neighborCount){
         return FALSE;
      }
      *info = neighbors[slot].info;
      return TRUE;
   }

   event void Boot.booted(){
      call AMControl.start();
   }

   event void AMControl.startDone(error_t error){
      if(error == SUCCESS){
         // Spread the first probe as well as later probes so motes booted near
         // one another do not immediately create a synchronized burst.
         uint16_t initialDelay = 1000 +
                                 (call Random.rand16() %
                                  (NEIGHBOR_PROBE_INTERVAL - 1000));
         call probeTimer.startOneShot(initialDelay);
      }else{
         call AMControl.start();
      }
   }

   event void AMControl.stopDone(error_t error){}

   event void probeTimer.fired(){
      uint8_t i;
      pack probe;
      error_t result;

      // A discovery request is broadcast with TTL=1; flooding delivers it
      // only to directly reachable motes, which then return a direct reply.
      probe.dest = AM_BROADCAST_ADDR;
      probe.src = TOS_NODE_ID;
      probe.seq = nextProbeSeq++;
      probe.TTL = 1;
      probe.protocol = PROTOCOL_NEIGHBOR_REQUEST;
      for(i = 0; i < PACKET_MAX_PAYLOAD_SIZE; i++){
         probe.payload[i] = emptyPayload[i];
      }

      result = call Sender.send(probe, AM_BROADCAST_ADDR);
      if(result != SUCCESS){
         // SUCCESS here means accepted into SimpleSend's queue, not yet sent
         // over the air. Do not count it as a probe until sendDone succeeds.
         dbg(NEIGHBOR_CHANNEL, "Unable to queue neighbor probe seq=%hu\n", probe.seq);
         scheduleNextProbe();
         return;
      }

      dbg(NEIGHBOR_CHANNEL, "Queued neighbor probe seq=%hu\n", probe.seq);
      scheduleNextProbe();
   }

   event void Sender.sendDone(pack message, error_t error){
      uint8_t i;

      // This shared sender also carries ping and reply traffic. Filter its
      // completion notifications so only our own requests affect statistics.
      if(message.protocol != PROTOCOL_NEIGHBOR_REQUEST ||
         message.src != TOS_NODE_ID){
         return;
      }
      if(error != SUCCESS){
         dbg(NEIGHBOR_CHANNEL, "Neighbor probe transmission failed seq=%hu error=%hhu\n",
             message.seq, error);
         return;
      }

      currentProbeSeq = message.seq;
      hasCurrentProbe = TRUE;
      for(i = 0; i < neighborCount; i++){
         // Each successfully transmitted probe is one opportunity for every
         // known neighbor to answer. Five consecutive misses mark it inactive.
         if(neighbors[i].probesSent < 65535){
            neighbors[i].probesSent++;
         }
         if(neighbors[i].missedProbes < 255){
            neighbors[i].missedProbes++;
         }
         if(neighbors[i].missedProbes >= MAX_MISSED_NEIGHBOR_PROBES){
            neighbors[i].info.active = FALSE;
         }
         updateQuality(i);
      }
      dbg(NEIGHBOR_CHANNEL, "Neighbor probe transmitted seq=%hu\n", message.seq);
   }

   event void Flooding.receive(pack message){
      if(message.protocol == PROTOCOL_NEIGHBOR_REQUEST){
         pack reply;
         uint8_t i;

         // Seeing a request proves the sender is currently reachable. Keep
         // the peer in the table even before it has replied to our own probe.
         ensureNeighbor(message.src);
         dbg(NEIGHBOR_CHANNEL, "Received neighbor probe from node %hu\n", message.src);
         reply.dest = message.src;
         reply.src = TOS_NODE_ID;
         reply.seq = message.seq;
         reply.TTL = 1;
         reply.protocol = PROTOCOL_NEIGHBOR_REPLY;
         for(i = 0; i < PACKET_MAX_PAYLOAD_SIZE; i++){
            reply.payload[i] = emptyPayload[i];
         }
         if(call Sender.send(reply, message.src) != SUCCESS){
            dbg(NEIGHBOR_CHANNEL, "Unable to queue neighbor reply to node %hu\n",
                message.src);
         }
         return;
      }

      if(message.protocol == PROTOCOL_NEIGHBOR_REPLY){
         uint8_t slot;

         // The sequence is echoed by the responder, correlating the reply to
         // this mote's latest transmitted probe rather than a later attempt.
         if(!hasCurrentProbe || message.seq != currentProbeSeq){
            dbg(NEIGHBOR_CHANNEL, "Ignoring stale neighbor reply from node %hu seq=%hu\n",
                message.src, message.seq);
            return;
         }

         slot = ensureNeighbor(message.src);
         if(slot == MAX_NEIGHBORS){
            return;
         }

         if(neighbors[slot].probesSent == 0){
            // This peer may have been unknown when the probe was transmitted,
            // so establish its first denominator sample with this reply.
            neighbors[slot].probesSent = 1;
         }
         if(neighbors[slot].repliesReceived < 65535){
            neighbors[slot].repliesReceived++;
         }
         // A matching reply resets consecutive loss and marks the neighbor
         // active; quality remains the cumulative reply/probe ratio.
         neighbors[slot].missedProbes = 0;
         neighbors[slot].info.active = TRUE;
         updateQuality(slot);
         dbg(NEIGHBOR_CHANNEL, "Received neighbor reply from node %hu\n", message.src);
      }
   }
}

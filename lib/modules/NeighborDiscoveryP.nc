#include "../../includes/packet.h"
#include "../../includes/neighbor.h"
#include "../../includes/channels.h"

#define MAX_NEIGHBORS 20
#define NEIGHBOR_PROBE_INTERVAL 30000
#define NEIGHBOR_PROBE_JITTER 5000
#define MAX_MISSED_NEIGHBOR_PROBES 5

typedef struct {
   neighborInfo info;
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
   neighborRecord neighbors[MAX_NEIGHBORS];
   uint8_t neighborCount = 0;
   uint16_t nextProbeSeq = 1;
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

      quality = ((uint32_t) neighbors[slot].repliesReceived * 100) /
                neighbors[slot].probesSent;
      if(quality > 100){
         quality = 100;
      }
      neighbors[slot].info.quality = quality;
   }

   void scheduleNextProbe(){
      uint16_t delay = NEIGHBOR_PROBE_INTERVAL - NEIGHBOR_PROBE_JITTER +
                      (call Random.rand16() %
                       ((2 * NEIGHBOR_PROBE_JITTER) + 1));
      call probeTimer.startOneShot(delay);
   }

   command uint8_t NeighborDiscovery.getNeighborCount(){
      return neighborCount;
   }

   command bool NeighborDiscovery.getNeighbor(uint8_t slot, neighborInfo *info){
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
         dbg(NEIGHBOR_CHANNEL, "Unable to queue neighbor probe seq=%hu\n", probe.seq);
         scheduleNextProbe();
         return;
      }

      dbg(NEIGHBOR_CHANNEL, "Queued neighbor probe seq=%hu\n", probe.seq);
      scheduleNextProbe();
   }

   event void Sender.sendDone(pack message, error_t error){
      uint8_t i;

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
            neighbors[slot].probesSent = 1;
         }
         if(neighbors[slot].repliesReceived < 65535){
            neighbors[slot].repliesReceived++;
         }
         neighbors[slot].missedProbes = 0;
         neighbors[slot].info.active = TRUE;
         updateQuality(slot);
         dbg(NEIGHBOR_CHANNEL, "Received neighbor reply from node %hu\n", message.src);
      }
   }
}

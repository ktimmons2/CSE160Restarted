#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"

#define MAX_SEEN_PACKETS 32
#define MAX_NEIGHBORS 20
#define NEIGHBOR_PROBE_INTERVAL 30000
#define MAX_MISSED_NEIGHBOR_PROBES 5

//defines cache structure
typedef struct {
    uint16_t src;
    uint16_t seq;
} seenPacket;

typedef struct {
   uint16_t address;
   uint16_t probesSent;
   uint16_t repliesReceived;
   uint8_t missedProbes;
   bool active;
} neighborRecord;

module Node{
   uses interface Boot;
   uses interface SplitControl as AMControl;
   uses interface Receive;
   uses interface SimpleSend as Sender;
   uses interface CommandHandler;
   uses interface Timer<TMilli> as neighborTimer;
}

implementation{
   pack sendPackage;
   uint16_t nextSeq = 1;
   uint8_t emptyPayload[PACKET_MAX_PAYLOAD_SIZE] = {0};

   seenPacket seenPackets[MAX_SEEN_PACKETS];
   uint8_t seenCount = 0;
   neighborRecord neighbors[MAX_NEIGHBORS];
   uint8_t neighborCount = 0;

   uint8_t findNeighbor(uint16_t address){
      uint8_t i;
      for(i = 0; i < neighborCount; i++){
         if(neighbors[i].address == address){
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
      neighbors[slot].address = address;
      neighbors[slot].probesSent = 0;
      neighbors[slot].repliesReceived = 0;
      neighbors[slot].missedProbes = 0;
      neighbors[slot].active = FALSE;
      return slot;
   }

   bool isPacketSeen(uint16_t src, uint16_t seq){
      uint8_t i;
      for(i = 0; i < seenCount; i++){
         if(seenPackets[i].src == src && seenPackets[i].seq == seq){
            return TRUE;
         }
      }
      return FALSE;
   }

   void markPacketSeen(uint16_t src, uint16_t seq){
      uint8_t i;

      // If it is already in the cache, do nothing
      if(isPacketSeen(src, seq)){
         return;
      }

      // If cache is full, drop the oldest entry
      if(seenCount >= MAX_SEEN_PACKETS){
         for(i = 1; i < MAX_SEEN_PACKETS; i++){
            seenPackets[i-1] = seenPackets[i];
         }
         seenCount--;
      }

      seenPackets[seenCount].src = src;
      seenPackets[seenCount].seq = seq;
      seenCount++;
   }

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL,
                uint16_t Protocol, uint16_t seq, void *payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = Protocol;
      memcpy(Package->payload, payload, length);
   }

   event void neighborTimer.fired(){
      uint8_t i;
      pack probe;

      for(i = 0; i < neighborCount; i++){
         if(neighbors[i].probesSent < 65535){
            neighbors[i].probesSent++;
         }
         if(neighbors[i].missedProbes < 255){
            neighbors[i].missedProbes++;
         }
         if(neighbors[i].missedProbes >= MAX_MISSED_NEIGHBOR_PROBES){
            neighbors[i].active = FALSE;
         }
      }

      makePack(&probe, TOS_NODE_ID, AM_BROADCAST_ADDR, 1,
               PROTOCOL_NEIGHBOR_REQUEST, nextSeq++, emptyPayload,
               PACKET_MAX_PAYLOAD_SIZE);
      markPacketSeen(probe.src, probe.seq);
      dbg(NEIGHBOR_CHANNEL, "Broadcasting neighbor probe seq=%hu\n", probe.seq);
      call Sender.send(probe, AM_BROADCAST_ADDR);
   }

   event void Boot.booted(){
      call AMControl.start();
      dbg(GENERAL_CHANNEL, "Booted\n");
   }

   event void AMControl.startDone(error_t err){
      if(err == SUCCESS){
         dbg(GENERAL_CHANNEL, "Radio On\n");
         call neighborTimer.startPeriodic(NEIGHBOR_PROBE_INTERVAL);
      }else{
         call AMControl.start();
      }
   }

   event void AMControl.stopDone(error_t err){}

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
      if(len == sizeof(pack)){
         pack* myMsg = (pack*) payload;
         pack forwarded;

         dbg(FLOODING_CHANNEL, "Received packet: src=%hu dest=%hu seq=%hu ttl=%hhu\n",
             myMsg->src, myMsg->dest, myMsg->seq, myMsg->TTL);

         // 1. Drop duplicate packets
         if(isPacketSeen(myMsg->src, myMsg->seq)){
            dbg(FLOODING_CHANNEL, "Duplicate packet dropped\n");
            return msg;
         }

         // 2. Drop expired packets before delivering or forwarding them.
         if(myMsg->TTL == 0){
            dbg(FLOODING_CHANNEL, "TTL expired; dropping packet\n");
            return msg;
         }

         // Remember valid packets before processing them so duplicates are ignored.
         markPacketSeen(myMsg->src, myMsg->seq);

         if(myMsg->protocol == PROTOCOL_NEIGHBOR_REQUEST){
            pack reply;

            ensureNeighbor(myMsg->src);
            dbg(NEIGHBOR_CHANNEL, "Received neighbor probe from node %hu\n", myMsg->src);
            makePack(&reply, TOS_NODE_ID, myMsg->src, 1,
                     PROTOCOL_NEIGHBOR_REPLY, nextSeq++, emptyPayload,
                     PACKET_MAX_PAYLOAD_SIZE);
            markPacketSeen(reply.src, reply.seq);
            call Sender.send(reply, myMsg->src);
            return msg;
         }

         if(myMsg->protocol == PROTOCOL_NEIGHBOR_REPLY){
            uint8_t neighborIndex = ensureNeighbor(myMsg->src);

            if(neighborIndex != MAX_NEIGHBORS){
               if(neighbors[neighborIndex].probesSent == 0){
                  neighbors[neighborIndex].probesSent = 1;
               }
               if(neighbors[neighborIndex].repliesReceived < 65535){
                  neighbors[neighborIndex].repliesReceived++;
               }
               neighbors[neighborIndex].missedProbes = 0;
               neighbors[neighborIndex].active = TRUE;
            }
            dbg(NEIGHBOR_CHANNEL, "Received neighbor reply from node %hu\n", myMsg->src);
            return msg;
         }

         // 4. If this is for me, process it
         if(myMsg->dest == TOS_NODE_ID){
            if(myMsg->protocol == PROTOCOL_PING){
               pack reply;

               dbg(GENERAL_CHANNEL, "Ping delivered to node %u from node %hu: %s\n",
                   TOS_NODE_ID, myMsg->src, myMsg->payload);

               makePack(&reply, TOS_NODE_ID, myMsg->src, MAX_TTL,
                        PROTOCOL_PINGREPLY, nextSeq++, myMsg->payload,
                        PACKET_MAX_PAYLOAD_SIZE);
               markPacketSeen(reply.src, reply.seq);
               dbg(FLOODING_CHANNEL, "Sending ping reply seq=%hu from=%hu to=%hu ttl=%hhu\n",
                   reply.seq, reply.src, reply.dest, reply.TTL);
               call Sender.send(reply, AM_BROADCAST_ADDR);
            }else if(myMsg->protocol == PROTOCOL_PINGREPLY){
               dbg(GENERAL_CHANNEL, "Ping reply received at node %u from node %hu: %s\n",
                   TOS_NODE_ID, myMsg->src, myMsg->payload);
            }else{
               dbg(GENERAL_CHANNEL, "Unsupported protocol %hhu at node %u\n",
                   myMsg->protocol, TOS_NODE_ID);
            }
            return msg;
         }

         // 5. Otherwise, decrement the hop limit and rebroadcast a copy.
         forwarded = *myMsg;
         forwarded.TTL = myMsg->TTL - 1;
         dbg(FLOODING_CHANNEL, "Forwarding packet from %hu with ttl=%hhu\n",
             TOS_NODE_ID, forwarded.TTL);

         // Use broadcast for the flood step; this matches the assignment's "broadcast to all nodes"
         call Sender.send(forwarded, AM_BROADCAST_ADDR);

         return msg;
      }

      dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);
      return msg;
   }

   event void CommandHandler.ping(uint16_t destination, uint8_t *payload){
      pack pkt;
      dbg(GENERAL_CHANNEL, "PING EVENT\n");

      makePack(&pkt, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING,
               nextSeq++, payload, PACKET_MAX_PAYLOAD_SIZE);

      dbg(FLOODING_CHANNEL, "Sending new flood packet seq=%hu from=%hu to=%hu ttl=%hu\n",
          pkt.seq, pkt.src, pkt.dest, pkt.TTL);

      // Mark the origin's packet so a copy returning through the network is dropped.
      markPacketSeen(pkt.src, pkt.seq);
      call Sender.send(pkt, AM_BROADCAST_ADDR);
   }

   event void CommandHandler.printNeighbors(){
      uint8_t i;
      for(i = 0; i < neighborCount; i++){
         uint8_t quality = 0;
         if(neighbors[i].probesSent > 0){
            quality = ((uint32_t) neighbors[i].repliesReceived * 100) /
                      neighbors[i].probesSent;
            if(quality > 100){
               quality = 100;
            }
         }
         dbg(NEIGHBOR_CHANNEL, "Neighbor %hu quality=%hhu%% active=%s\n",
             neighbors[i].address, quality,
             neighbors[i].active ? "yes" : "no");
      }
   }
   event void CommandHandler.printRouteTable(){}
   event void CommandHandler.printLinkState(){}
   event void CommandHandler.printDistanceVector(){}
   event void CommandHandler.setTestServer(){}
   event void CommandHandler.setTestClient(){}
   event void CommandHandler.setAppServer(){}
   event void CommandHandler.setAppClient(){}
}
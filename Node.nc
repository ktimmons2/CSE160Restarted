#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"

#define MAX_SEEN_PACKETS 32

//defines cache structure
typedef struct {
    uint16_t src;
    uint16_t seq;
} seenPacket;

module Node{
   uses interface Boot;
   uses interface SplitControl as AMControl;
   uses interface Receive;
   uses interface SimpleSend as Sender;
   uses interface CommandHandler;
}

implementation{
   pack sendPackage;
   uint16_t nextSeq = 1;

   seenPacket seenPackets[MAX_SEEN_PACKETS];
   uint8_t seenCount = 0;

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
                uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = Protocol;
      memcpy(Package->payload, payload, length);
   }

   event void Boot.booted(){
      call AMControl.start();
      dbg(GENERAL_CHANNEL, "Booted\n");
   }

   event void AMControl.startDone(error_t err){
      if(err == SUCCESS){
         dbg(GENERAL_CHANNEL, "Radio On\n");
      }else{
         call AMControl.start();
      }
   }

   event void AMControl.stopDone(error_t err){}

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
      if(len == sizeof(pack)){
         pack* myMsg = (pack*) payload;

         dbg(FLOODING_CHANNEL, "Received packet: src=%hu dest=%hu seq=%hu ttl=%hhu\n",
             myMsg->src, myMsg->dest, myMsg->seq, myMsg->TTL);

         // 1. Drop duplicate packets
         if(isPacketSeen(myMsg->src, myMsg->seq)){
            dbg(FLOODING_CHANNEL, "Duplicate packet dropped\n");
            return msg;
         }

         // 2. Drop expired packets
         if(myMsg->TTL == 0){
            dbg(FLOODING_CHANNEL, "TTL expired; dropping packet\n");
            return msg;
         }
         //3. Mark this packet as seen
         markPacketSeen(myMsg->src, myMsg->seq);

         // 4. If this is for me, process it
         if(myMsg->dest == TOS_NODE_ID){
            dbg(GENERAL_CHANNEL, "Packet delivered to node %u: %s\n",
                TOS_NODE_ID, myMsg->payload);
            return msg;
         }

         // 5. Otherwise, decrement the hop limit and rebroadcast a copy.
         forwarded = *myMsg;
         forwarded.TTL--;
         dbg(FLOODING_CHANNEL, "Forwarding packet from %hu with ttl=%hhu\n", TOS_NODE_ID, forwarded.TTL);

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

      makePack(&pkt, TOS_NODE_ID, destination, MAX_TTL, 0, nextSeq++, payload, PACKET_MAX_PAYLOAD_SIZE);

      dbg(FLOODING_CHANNEL, "Sending new flood packet seq=%hu from=%hu to=%hu ttl=%hu\n",
          pkt.seq, pkt.src, pkt.dest, pkt.TTL);

       // Mark the origin's packet so a copy returning through the network is dropped.
      markPacketSeen(pkt.src, pkt.seq);
      call Sender.send(pkt, AM_BROADCAST_ADDR);
   }

   event void CommandHandler.printNeighbors(){}
   event void CommandHandler.printRouteTable(){}
   event void CommandHandler.printLinkState(){}
   event void CommandHandler.printDistanceVector(){}
   event void CommandHandler.setTestServer(){}
   event void CommandHandler.setTestClient(){}
   event void CommandHandler.setAppServer(){}
   event void CommandHandler.setAppClient(){}
}
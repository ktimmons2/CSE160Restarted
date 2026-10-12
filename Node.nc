#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/neighbor.h"
#include "includes/channels.h"

module Node{
   uses interface Boot;
   uses interface Flooding;
   uses interface NeighborDiscovery;
   uses interface CommandHandler;
}

implementation{
   event void Boot.booted(){
      dbg(GENERAL_CHANNEL, "Booted\n");
   }

   event void Flooding.receive(pack message){
      if(message.protocol == PROTOCOL_PING){
         dbg(GENERAL_CHANNEL, "Ping delivered to node %u from node %hu: %s\n",
             TOS_NODE_ID, message.src, message.payload);
         call Flooding.send(message.src, PROTOCOL_PINGREPLY,
                            message.payload, PACKET_MAX_PAYLOAD_SIZE);
      }else if(message.protocol == PROTOCOL_PINGREPLY){
         dbg(GENERAL_CHANNEL, "Ping reply received at node %u from node %hu: %s\n",
             TOS_NODE_ID, message.src, message.payload);
      }
   }

   event void CommandHandler.ping(uint16_t destination, uint8_t *payload){
      dbg(GENERAL_CHANNEL, "PING EVENT\n");
      call Flooding.send(destination, PROTOCOL_PING, payload,
                         PACKET_MAX_PAYLOAD_SIZE);
   }

   event void CommandHandler.printNeighbors(){
      uint8_t i;
      uint8_t count = call NeighborDiscovery.getNeighborCount();
      neighborInfo info;

      for(i = 0; i < count; i++){
         if(call NeighborDiscovery.getNeighbor(i, &info)){
            dbg(NEIGHBOR_CHANNEL, "Neighbor %hu quality=%hhu%% active=%s\n",
                info.address, info.quality,
                info.active ? "yes" : "no");
         }
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

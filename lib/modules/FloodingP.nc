#include "../../includes/packet.h"
#include "../../includes/channels.h"

#define MAX_SEEN_PACKETS 32

typedef struct {
   uint16_t src;
   uint16_t seq;
   uint8_t protocol;
} seenPacket;

generic module FloodingP(){
   provides interface Flooding;
   uses interface Receive;
   uses interface SimpleSend as Sender;
}

implementation{
   seenPacket seenPackets[MAX_SEEN_PACKETS];
   uint8_t seenCount = 0;
   uint16_t nextSeq = 1;

   bool isPacketSeen(uint16_t src, uint16_t seq, uint8_t protocol){
      uint8_t i;
      for(i = 0; i < seenCount; i++){
         if(seenPackets[i].src == src &&
            seenPackets[i].seq == seq &&
            seenPackets[i].protocol == protocol){
            return TRUE;
         }
      }
      return FALSE;
   }

   void markPacketSeen(uint16_t src, uint16_t seq, uint8_t protocol){
      uint8_t i;

      if(isPacketSeen(src, seq, protocol)){
         return;
      }

      if(seenCount >= MAX_SEEN_PACKETS){
         for(i = 1; i < MAX_SEEN_PACKETS; i++){
            seenPackets[i - 1] = seenPackets[i];
         }
         seenCount--;
      }

      seenPackets[seenCount].src = src;
      seenPackets[seenCount].seq = seq;
      seenPackets[seenCount].protocol = protocol;
      seenCount++;
   }

   command error_t Flooding.send(uint16_t destination, uint8_t protocol,
                                void *payload, uint8_t length){
      pack message;
      uint8_t i;
      error_t result;
      uint8_t *payloadBytes = payload;

      if(length > PACKET_MAX_PAYLOAD_SIZE){
         dbg(FLOODING_CHANNEL, "Payload too large to flood: %hhu bytes\n", length);
         return FAIL;
      }

      message.dest = destination;
      message.src = TOS_NODE_ID;
      message.seq = nextSeq++;
      message.TTL = MAX_TTL;
      message.protocol = protocol;
      for(i = 0; i < PACKET_MAX_PAYLOAD_SIZE; i++){
         message.payload[i] = 0;
      }
      for(i = 0; i < length; i++){
         message.payload[i] = payloadBytes[i];
      }

      dbg(FLOODING_CHANNEL, "Sending packet seq=%hu from=%hu to=%hu ttl=%hhu\n",
          message.seq, message.src, message.dest, message.TTL);
      result = call Sender.send(message, AM_BROADCAST_ADDR);
      if(result == SUCCESS){
         markPacketSeen(message.src, message.seq, message.protocol);
      }else{
         dbg(FLOODING_CHANNEL, "Unable to queue packet seq=%hu error=%hhu\n",
             message.seq, result);
      }
      return result;
   }

   event message_t* Receive.receive(message_t* rawMessage, void* payload,
                                    uint8_t length){
      pack* message;
      pack forwarded;

      if(length != sizeof(pack)){
         dbg(FLOODING_CHANNEL, "Ignoring packet with unexpected length %hhu\n", length);
         return rawMessage;
      }

      message = (pack*) payload;
      dbg(FLOODING_CHANNEL,
          "Received packet: src=%hu dest=%hu seq=%hu ttl=%hhu protocol=%hhu\n",
          message->src, message->dest, message->seq,
          message->TTL, message->protocol);

      if(isPacketSeen(message->src, message->seq, message->protocol)){
         dbg(FLOODING_CHANNEL, "Duplicate packet dropped\n");
         return rawMessage;
      }

      if(message->TTL == 0){
         dbg(FLOODING_CHANNEL, "TTL expired; dropping packet\n");
         return rawMessage;
      }

      markPacketSeen(message->src, message->seq, message->protocol);

      if(message->protocol == PROTOCOL_NEIGHBOR_REQUEST ||
         message->protocol == PROTOCOL_NEIGHBOR_REPLY){
         signal Flooding.receive(*message);
         return rawMessage;
      }

      if(message->dest == TOS_NODE_ID){
         signal Flooding.receive(*message);
         return rawMessage;
      }

      forwarded = *message;
      forwarded.TTL = message->TTL - 1;
      dbg(FLOODING_CHANNEL, "Forwarding packet from node %hu with ttl=%hhu\n",
          TOS_NODE_ID, forwarded.TTL);
      if(call Sender.send(forwarded, AM_BROADCAST_ADDR) != SUCCESS){
         dbg(FLOODING_CHANNEL, "Unable to queue forwarded packet seq=%hu\n",
             forwarded.seq);
      }
      return rawMessage;
   }
}

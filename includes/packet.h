//Author: UCM ANDES Lab
//$Author: abeltran2 $
//$LastChangedBy: abeltran2 $

#ifndef PACKET_H
#define PACKET_H


# include "protocol.h"
#include "channels.h"

enum{
	PACKET_HEADER_LENGTH = 8,
	PACKET_MAX_PAYLOAD_SIZE = 28 - PACKET_HEADER_LENGTH,
	// A hop limit bounds the lifetime of a flood even after old cache entries
	// have been evicted.
	MAX_TTL = 15
};


typedef nx_struct pack{
	nx_uint16_t dest;
	nx_uint16_t src;		// Originating node; preserved across all flood hops.
	nx_uint16_t seq;		// Origin's sequence number; distinguishes new floods.
	nx_uint8_t TTL;		// Decremented at each forwarding hop.
	nx_uint8_t protocol;
	nx_uint8_t payload[PACKET_MAX_PAYLOAD_SIZE];
}pack;

/*
 * logPack
 * 	Sends packet information to the general channel.
 * @param:
 * 		pack *input = pack to be printed.
 */
void logPack(pack *input){
	dbg(GENERAL_CHANNEL, "Src: %hhu Dest: %hhu Seq: %hhu TTL: %hhu Protocol:%hhu  Payload: %s\n",
	input->src, input->dest, input->seq, input->TTL, input->protocol, input->payload);
}

enum{
	AM_PACK=6
};

#endif

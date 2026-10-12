#include "../../includes/packet.h"

interface Flooding{
   // Originate a new packet with this node as source and have the service
   // flood it. Oversized payloads fail rather than being truncated.
   command error_t send(uint16_t destination, uint8_t protocol,
                       void *payload, uint8_t length);

   // Signaled for a newly accepted packet at its destination, or for a
   // one-hop discovery packet.
   event void receive(pack message);
}

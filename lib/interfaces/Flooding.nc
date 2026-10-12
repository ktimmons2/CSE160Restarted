#include "../../includes/packet.h"

interface Flooding{
   command error_t send(uint16_t destination, uint8_t protocol,
                       void *payload, uint8_t length);
   event void receive(pack message);
}

#include "../../includes/packet.h"

interface SimpleSend{
   command error_t send(pack msg, uint16_t dest );
   event void sendDone(pack msg, error_t error);
}

#include "../../includes/packet.h"

interface SimpleSend{
   // Queue a packet for transmission. SUCCESS means queued, not transmitted;
   // callers that need radio completion should wait for sendDone.
   command error_t send(pack msg, uint16_t dest );

   // Reports the packet accepted by the radio layer after its transmission
   // attempt completes, including the radio's success/failure result.
   event void sendDone(pack msg, error_t error);
}

#include "../../includes/neighbor.h"

interface NeighborDiscovery{
   // The table contains only neighbors observed directly through discovery
   // requests or replies; slots remain valid from zero to count - 1.
   command uint8_t getNeighborCount();

   // Copy one public address/quality/active record to the caller.
   command bool getNeighbor(uint8_t slot, neighborInfo *info);
}

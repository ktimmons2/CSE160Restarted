#include "../../includes/neighbor.h"

interface NeighborDiscovery{
   command uint8_t getNeighborCount();
   command bool getNeighbor(uint8_t slot, neighborInfo *info);
}

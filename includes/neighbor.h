#ifndef NEIGHBOR_H
#define NEIGHBOR_H

typedef struct {
   uint16_t address; // Direct neighbor's node ID.
   uint8_t quality;  // Percentage of this node's probes answered (0-100).
   bool active;      // Cleared after five consecutive unanswered probes.
} neighborInfo;

#endif

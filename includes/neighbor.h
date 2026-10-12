#ifndef NEIGHBOR_H
#define NEIGHBOR_H

typedef struct {
   uint16_t address;
   uint8_t quality;
   bool active;
} neighborInfo;

#endif

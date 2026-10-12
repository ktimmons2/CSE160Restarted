/**
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */

#include <Timer.h>
#include "includes/CommandMsg.h"
#include "includes/packet.h"

configuration NodeC{
}
implementation {
    components MainC;
    components Node;
    components new AMReceiverC(AM_PACK) as GeneralReceive;

    Node -> MainC.Boot;

    components new SimpleSendC(AM_PACK) as Sender;
    components FloodingC;
    components NeighborDiscoveryC;

    FloodingC.Receive -> GeneralReceive;
    FloodingC.Sender -> Sender;
    NeighborDiscoveryC.Flooding -> FloodingC.Flooding;
    NeighborDiscoveryC.Sender -> Sender;
    Node.Flooding -> FloodingC.Flooding;
    Node.NeighborDiscovery -> NeighborDiscoveryC;

    components CommandHandlerC;
    Node.CommandHandler -> CommandHandlerC;
}

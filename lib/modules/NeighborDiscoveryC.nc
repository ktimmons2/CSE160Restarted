configuration NeighborDiscoveryC{
   provides interface NeighborDiscovery;
   uses interface Flooding;
   uses interface SimpleSend as Sender;
}

implementation{
   components NeighborDiscoveryP as DiscoveryLogic;
   components MainC;
   components ActiveMessageC;
   components new TimerMilliC() as ProbeTimer;

   NeighborDiscovery = DiscoveryLogic.NeighborDiscovery;
   DiscoveryLogic.Boot -> MainC.Boot;
   DiscoveryLogic.AMControl -> ActiveMessageC;
   DiscoveryLogic.probeTimer -> ProbeTimer;
   Flooding = DiscoveryLogic.Flooding;
   Sender = DiscoveryLogic.Sender;
}

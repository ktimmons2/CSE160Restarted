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
   components RandomC;

   NeighborDiscovery = DiscoveryLogic.NeighborDiscovery;
   DiscoveryLogic.Boot -> MainC.Boot;
   DiscoveryLogic.AMControl -> ActiveMessageC;
   DiscoveryLogic.probeTimer -> ProbeTimer;
   DiscoveryLogic.Random -> RandomC;
   Flooding = DiscoveryLogic.Flooding;
   Sender = DiscoveryLogic.Sender;
}

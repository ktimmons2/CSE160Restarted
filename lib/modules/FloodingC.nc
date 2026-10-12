configuration FloodingC{
   provides interface Flooding;
   uses interface Receive;
   uses interface SimpleSend as Sender;
}

implementation{
   components new FloodingP() as FloodingLogic;

   // Export one reusable flooding service and connect its radio-facing
   // receive/send interfaces. Application and discovery modules depend on
   // the Flooding interface rather than implementing forwarding themselves.
   Flooding = FloodingLogic.Flooding;
   Receive = FloodingLogic.Receive;
   Sender = FloodingLogic.Sender;
}

configuration FloodingC{
   provides interface Flooding;
   uses interface Receive;
   uses interface SimpleSend as Sender;
}

implementation{
   components new FloodingP() as FloodingLogic;

   Flooding = FloodingLogic.Flooding;
   Receive = FloodingLogic.Receive;
   Sender = FloodingLogic.Sender;
}

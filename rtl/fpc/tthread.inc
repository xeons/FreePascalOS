{
  TThread for FreePascalOS: the Unix RTL's implementation, which is
  built only on BeginThread, RTL events and WaitForThreadTerminate.
  Suspending a thread from another one is not supported; a thread may
  suspend itself.
}

{$i unix/tthread.inc}

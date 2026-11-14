{
  Classes for FreePascalOS: the generic Free Pascal Classes unit
  (rtl/objpas/classes). TThread is the portable one of the Unix RTL
  (tthread.inc), which needs nothing but the thread manager of System.
}
{$mode objfpc}
{$H+}
{ Classes declares and starts TThread the Unix way when UNIX is defined,
  which is the model tthread.inc implements; nothing else in the unit
  depends on it. }
{$define UNIX}
unit Classes;

{$inline on}

interface

uses
  SysUtils,
  Types,
  TypInfo,
  RtlConsts;

{$i classesh.inc}

implementation

{$i classes.inc}

initialization
  CommonInit;
finalization
  CommonCleanup;
  if ThreadsInited then
    DoneThreads;
end.

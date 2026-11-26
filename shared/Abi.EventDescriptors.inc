{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  The constants and records of the event descriptor calls (260-269):
  event counters, timer descriptors, signal descriptors, event polls and
  watch groups. Values and layouts are Linux's where Linux has the same
  thing (eventfd, timerfd, signalfd, epoll, inotify), so the C library
  passes them through. Included at the end of Abi.SystemCalls.inc.
}

const
  { Flags of the calls that make event descriptors. }
  EventDescriptorNonBlocking = $800;
  { CallCreateEventCounter: a read takes one, not the whole count. }
  EventCounterSemaphore = 1;
  { The largest count an event counter holds. }
  EventCounterMaximum = QWord($FFFFFFFFFFFFFFFE);

  { CallCreateTimerDescriptor clocks (the Linux clock ids). }
  TimerClockRealTime = 0;
  TimerClockMonotonic = 1;
  TimerClockBoot = 7;
  { CallSetTimerDescriptor flags. }
  TimerAbsolute = 1;
  TimerCancelOnSet = 2;

  { What an object is ready for (CallQueryHandleReadiness, event polls):
    the Linux POLL* and EPOLL* values. }
  PollReadable = $001;
  PollPriority = $002;
  PollWritable = $004;
  PollError = $008;
  PollHangUp = $010;
  PollReadHangUp = $2000;
  { Registration flags of an event poll. }
  PollExclusive = LongWord(1) shl 28;
  PollWakeUp = LongWord(1) shl 29;
  PollOneShot = LongWord(1) shl 30;
  PollEdgeTriggered = LongWord(1) shl 31;
  { CallControlEventPoll operations. }
  PollAdd = 1;
  PollRemove = 2;
  PollModify = 3;
  { At most this many records per CallWaitEventPoll. }
  PollMaximumEvents = 1024;
  { Polls inside polls, at most this deep. }
  PollMaximumNesting = 4;

  { Watch group events and flags (the Linux IN_* values). }
  GroupWatchAccess = $00000001;
  GroupWatchModify = $00000002;
  GroupWatchAttributes = $00000004;
  GroupWatchCloseWrite = $00000008;
  GroupWatchCloseNoWrite = $00000010;
  GroupWatchOpen = $00000020;
  GroupWatchMovedFrom = $00000040;
  GroupWatchMovedTo = $00000080;
  GroupWatchCreate = $00000100;
  GroupWatchDelete = $00000200;
  GroupWatchDeleteSelf = $00000400;
  GroupWatchMoveSelf = $00000800;
  GroupWatchUnmount = $00002000;
  GroupWatchQueueOverflow = $00004000;
  GroupWatchIgnored = $00008000;
  GroupWatchOnlyDirectory = $01000000;
  GroupWatchDontFollow = $02000000;
  GroupWatchExcludeUnlinked = $04000000;
  GroupWatchMaskCreate = $10000000;
  GroupWatchMaskAdd = $20000000;
  GroupWatchIsDirectory = $40000000;
  GroupWatchOneShot = $80000000;
  { The events a watch may ask for. }
  GroupWatchAllEvents = $00000FFF;
  { CallChangeGroupWatch operations. }
  GroupWatchAdd = 1;
  GroupWatchRemove = 2;
  { Records queued in a group at most; then one GroupWatchQueueOverflow
    record, and nothing more until the program has read. }
  GroupWatchMaximumQueued = 4096;

  { TAbiSignalDescriptorRecord.Code: sent by a process (kill), or by the
    kernel. }
  SignalCodeUser = 0;
  SignalCodeKernel = $80;
  { sigqueue (SI_QUEUE) and a POSIX timer (SI_TIMER). }
  SignalCodeQueue = -1;
  SignalCodeTimer = -2;

type
  { CallSetTimerDescriptor (struct itimerspec): the period (zero: once)
    and the first time (zero: stopped). }
  TAbiTimerSpecification = record
    IntervalSeconds: Int64;
    IntervalNanoseconds: Int64;
    ValueSeconds: Int64;
    ValueNanoseconds: Int64;
  end;
  PAbiTimerSpecification = ^TAbiTimerSpecification;

  { One event of CallWaitEventPoll, and the registration of
    CallControlEventPoll: Poll* bits and the program's own value. }
  TAbiPollEvent = record
    Events: LongWord;
    Reserved: LongWord;
    Data: QWord;
  end;
  PAbiPollEvent = ^TAbiPollEvent;

  { A signal read from a signal descriptor (struct signalfd_siginfo, 128
    bytes). }
  TAbiSignalDescriptorRecord = record
    Signal: LongWord;
    ErrorNumber: LongInt;
    Code: LongInt;
    SenderProcessId: LongWord;
    SenderUserId: LongWord;
    Descriptor: LongInt;
    { A timer's id (ssi_tid). }
    TimerId: LongWord;
    Band: LongWord;
    Overrun: LongWord;
    TrapNumber: LongWord;
    Status: LongInt;
    { sigqueue's and timers' value (ssi_int, ssi_ptr). }
    IntegerValue: LongInt;
    PointerValue: QWord;
    UserTime: QWord;
    SystemTime: QWord;
    Address: QWord;
    Reserved: array[0..47] of Byte;
  end;
  PAbiSignalDescriptorRecord = ^TAbiSignalDescriptorRecord;

  { A record of a watch group (struct inotify_event): the watch
    descriptor (-1 for GroupWatchQueueOverflow), the GroupWatch* event
    (with GroupWatchIsDirectory), the cookie that pairs a
    GroupWatchMovedFrom with its GroupWatchMovedTo, and the length of
    the name that follows (zero padded to a multiple of 16; 0 for none:
    an event of the watched item itself). }
  TAbiGroupWatchRecord = record
    Descriptor: LongInt;
    Mask: LongWord;
    Cookie: LongWord;
    NameLength: LongWord;
  end;
  PAbiGroupWatchRecord = ^TAbiGroupWatchRecord;

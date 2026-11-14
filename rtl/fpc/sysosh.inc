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
  Platform types of the FreePascalOS System unit.

  Handles are the kernel's handle numbers (small, so a LongInt as on
  Unix). A thread id (TThreadID) is the handle of the thread, which
  BeginThread returns and WaitForThreadTerminate waits on.
}

type
  THandle = LongInt;
  TThreadID = PtrUInt;

  { A recursive lock: State is 0 (free), 1 (held) or 2 (held, with
    threads sleeping on it in the kernel); Owner and Depth make it
    recursive, as critical sections must be. }
  PRTLCriticalSection = ^TRTLCriticalSection;
  TRTLCriticalSection = record
    State: LongInt;
    Depth: LongInt;
    Owner: QWord;
    Reserved: QWord;
  end;

  { What the startup code (si_prc) hands over besides the compiler's
    tables: the initial stack and how to end the process. }
  {$define HAS_ENTRYINFORMATION_OS}
  TEntryInformationOS = record
    argc: LongInt;
    argv: PPChar;
    envp: PPChar;
    { The auxiliary vector, after the environment. }
    auxv: PQWord;
    stkptr: Pointer;
    stklen: SizeUInt;
  end;

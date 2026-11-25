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
  The back trace of a program the kernel ends (Processes.UserProcess):
  the chain of calls that led to the fault, written to the kernel log
  between the report's first line and its module list:

    [process]   #0 0x0000000000408C76 coretest+0x8C76 CORETEST.CRASHONPURPOSE+0x6
    [process]   #1 0x0000000000408D2B coretest+0x8D2B main+0xAB

  Each frame is unwound by call frame information where there is some
  for its address (Processes.CallFrameEntries, .CallFrameRules): the
  module's loaded .eh_frame through the .eh_frame_hdr its
  PT_GNU_EH_FRAME names (C code), else the .debug_frame of its file
  (Free Pascal's), read once per report; else by the frame pointer.
  The walk trusts nothing: user memory is read only through the copy
  routines (a bad address ends the trace), each frame's stack pointer
  must lie above the last, a frame pointer at or above it, and it stops
  after UserBackTraceDepth frames, at address 0, or at a return address
  in no module and no executable region (what the outermost frame
  leaves above it). A return address is
  looked up by the call before it (address - 1).

  The routines are named from the module file's .symtab, else the
  loader's dynamic symbols (Processes.UserSymbols), as
  scripts/symbolize.py would (Processes.SymbolNames). Runs in the
  ending thread, at passive level, in its address space.
}
unit Processes.UserBackTrace;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.Arch.TrapFrame,
  Processes.Process;

const
  UserBackTraceDepth = 32;
  { The largest .debug_frame read from a module file. }
  DebugFrameReadLimit = 8 * 1024 * 1024;

{ Writes the back trace of the program Frame interrupted (a thread of
  Process, the current one) under Tag. }
procedure WriteUserBackTrace(Process: PProcess; Frame: PTrapFrame; Tag: PChar);

implementation

uses
  Runtime.Memory,
  Elf64,
  Abi.SystemCalls,
  Kernel.Mutex,
  Memory.KernelHeap,
  Memory.Arch.PageTables,
  Processes.ImageLoader,
  Processes.UserAccess,
  Processes.ModuleFiles,
  Processes.CallFrameEntries,
  Processes.CallFrameRules,
  Processes.SymbolNames,
  Processes.UserSymbols,
  Processes.Arch.UnwindRegisters,
  Debug.Output;

const
  ProgramHeaderTypeEhFrameHeader = $6474E550;
  NoModule = -1;

type
  TTraceModule = record
    Name: array[0..ModuleNameLength - 1] of Char;
    Base: QWord;
    Limit: QWord;
    ImageStart: QWord;
    ImageEnd: QWord;
    Symbols: PElf64Symbol;
    SymbolCount: LongWord;
    Strings: PChar;
    StringsSize: QWord;
    { Looked at once: its file, its code's link addresses, the
      .eh_frame_hdr (0: none) and the .debug_frame read from the file. }
    Prepared: Boolean;
    HasFile: Boolean;
    ModuleFile: TModuleFile;
    CodeStart: QWord;
    CodeEnd: QWord;
    EhFrameHeader: QWord;
    DebugFrame: PByte;
    DebugFrameSize: QWord;
  end;
  PTraceModule = ^TTraceModule;

  TTraceFrame = record
    Pc: QWord;
    ModuleIndex: Integer;
    Symbol: TSymbolMatch;
  end;

  TTrace = record
    Modules: array[0..MaximumModules - 1] of TTraceModule;
    ModuleCount: Integer;
    Frames: array[0..UserBackTraceDepth - 1] of TTraceFrame;
    FrameCount: Integer;
    Entry: TFrameEntry;
    Architecture: TCfiArchitecture;
    Memory: TCfiMemory;
  end;
  PTrace = ^TTrace;

function ReadUserMemory(Context: Pointer; Address: QWord; Buffer: Pointer; Count: LongWord): Boolean;
begin
  Result := CopyFromUser(Buffer, Address, Count) = ErrorNone;
end;

{ Copies what the trace needs of the process's modules (the list
  changes under the process's lock; modules stay until it ends). }
procedure TakeModules(Process: PProcess; Trace: PTrace);
var
  List: PModuleList;
  Index: Integer;
  Module: PLoadedModule;
  Target: PTraceModule;
begin
  AcquireMutex(Process^.Lock);
  List := PModuleList(Process^.Modules);
  if List <> nil then
    for Index := 0 to List^.Count - 1 do
    begin
      Module := List^.Modules[Index];
      if (Module = nil) or (Trace^.ModuleCount >= MaximumModules) then
        Continue;
      Target := @Trace^.Modules[Trace^.ModuleCount];
      CopyMemory(@Target^.Name[0], @Module^.Name[0], ModuleNameLength);
      Target^.Name[ModuleNameLength - 1] := #0;
      Target^.Base := Module^.Base;
      Target^.Limit := Module^.Limit;
      Target^.ImageStart := Module^.ImageStart;
      Target^.ImageEnd := Module^.ImageEnd;
      Target^.Symbols := PElf64Symbol(Module^.Symbols);
      Target^.SymbolCount := Module^.SymbolCount;
      Target^.Strings := Module^.Strings;
      Target^.StringsSize := Module^.StringsSize;
      Inc(Trace^.ModuleCount);
    end;
  ReleaseMutex(Process^.Lock);
end;

function ModuleOfAddress(Trace: PTrace; Address: QWord): Integer;
var
  Index: Integer;
begin
  for Index := 0 to Trace^.ModuleCount - 1 do
    if (Address >= Trace^.Modules[Index].ImageStart) and (Address < Trace^.Modules[Index].Limit) then
      Exit(Index);
  Result := NoModule;
end;

procedure ReadDebugFrame(Module: PTraceModule);
var
  Section: TElf64SectionHeader;
begin
  if not FindModuleSection(Module^.ModuleFile, '.debug_frame', Section) or (Section.Size = 0) or
     (Section.Size > DebugFrameReadLimit) then
    Exit;
  Module^.DebugFrame := PByte(AllocateKernelMemory(Section.Size));
  if Module^.DebugFrame = nil then
    Exit;
  if ReadModuleFile(Module^.ModuleFile, Section.FileOffset, Module^.DebugFrame, Section.Size) then
    Module^.DebugFrameSize := Section.Size
  else
  begin
    FreeKernelMemory(Module^.DebugFrame);
    Module^.DebugFrame := nil;
  end;
end;

procedure PrepareModule(Process: PProcess; Module: PTraceModule);
var
  ProgramHeader: TElf64ProgramHeader;
begin
  if Module^.Prepared then
    Exit;
  Module^.Prepared := True;
  Module^.HasFile := OpenModuleFile(Process^.AddressSpace, Module^.ImageStart, Module^.ImageEnd,
    Module^.ModuleFile);
  if not Module^.HasFile then
    Exit;
  ExecutableRange(Module^.ModuleFile, Module^.CodeStart, Module^.CodeEnd);
  if FindProgramHeader(Module^.ModuleFile, ProgramHeaderTypeEhFrameHeader, ProgramHeader) then
    Module^.EhFrameHeader := Module^.Base + ProgramHeader.VirtualAddress;
  ReadDebugFrame(Module);
end;

{ Finds the call frame information for LookupPc in its module. }
function FindFrameEntry(Process: PProcess; Trace: PTrace; ModuleIndex: Integer; LookupPc: QWord): Boolean;
var
  Module: PTraceModule;
begin
  Result := False;
  if ModuleIndex = NoModule then
    Exit;
  Module := @Trace^.Modules[ModuleIndex];
  PrepareModule(Process, Module);
  if (Module^.EhFrameHeader <> 0) and FindInEhFrameHeader(Trace^.Memory, Module^.EhFrameHeader, LookupPc,
     Trace^.Entry) then
    Exit(True);
  if Module^.DebugFrame <> nil then
    Result := FindInFrameSection(Module^.DebugFrame, Module^.DebugFrameSize, False, 0, Module^.Base,
      Module^.CodeStart, Module^.CodeEnd, LookupPc, Trace^.Entry);
end;

{ The caller's registers, by call frame information or the frame
  pointer; False where the walk ends. }
function UnwindFrame(Process: PProcess; Trace: PTrace; ModuleIndex: Integer; LookupPc: QWord;
  var Registers: TUnwindRegisters): Boolean;
var
  Caller: TUnwindRegisters;
  Rules: TFrameRules;
  StackPointer: QWord;
  FramePointer: QWord;
begin
  Result := False;
  if not RegisterIsKnown(Registers, Trace^.Architecture.StackPointerIndex) then
    Exit;
  StackPointer := Registers.Values[Trace^.Architecture.StackPointerIndex];
  Caller := Registers;
  if FindFrameEntry(Process, Trace, ModuleIndex, LookupPc) and ComputeFrameRules(Trace^.Entry, LookupPc, Rules) and
     ApplyFrameRules(Rules, Trace^.Architecture, Trace^.Memory, Caller) then
    Result := True
  else
  begin
    Caller := Registers;
    if RegisterIsKnown(Caller, Trace^.Architecture.FramePointerIndex) then
    begin
      FramePointer := Caller.Values[Trace^.Architecture.FramePointerIndex];
      Result := (FramePointer >= StackPointer) and UnwindWithFramePointer(Trace^.Architecture, Trace^.Memory, Caller);
    end;
  end;
  if not Result then
    Exit;
  { Every caller's frame lies above its callee's. }
  if not RegisterIsKnown(Caller, Trace^.Architecture.StackPointerIndex) or
     (Caller.Values[Trace^.Architecture.StackPointerIndex] <= StackPointer) then
    Exit(False);
  Registers := Caller;
end;

procedure CollectFrames(Process: PProcess; Frame: PTrapFrame; Trace: PTrace);
var
  Registers: TUnwindRegisters;
  Pc: QWord;
  LookupPc: QWord;
  ModuleIndex: Integer;
begin
  TakeUnwindRegisters(Frame, Registers);
  while Trace^.FrameCount < UserBackTraceDepth do
  begin
    if not RegisterIsKnown(Registers, Trace^.Architecture.ProgramCounterIndex) then
      Break;
    Pc := Registers.Values[Trace^.Architecture.ProgramCounterIndex];
    if (Pc = 0) or (Pc >= UserSpaceLimit) then
      Break;
    LookupPc := Pc;
    if Trace^.FrameCount > 0 then
      LookupPc := Pc - 1;
    ModuleIndex := ModuleOfAddress(Trace, LookupPc);
    { Past the first frame, a return address must be code: what the
      outermost frame leaves (the program's arguments) is not. }
    if (Trace^.FrameCount > 0) and (ModuleIndex = NoModule) and
       not AddressIsExecutable(Process^.AddressSpace, LookupPc) then
      Break;
    Trace^.Frames[Trace^.FrameCount].Pc := Pc;
    Trace^.Frames[Trace^.FrameCount].ModuleIndex := ModuleIndex;
    Inc(Trace^.FrameCount);
    if not UnwindFrame(Process, Trace, ModuleIndex, LookupPc, Registers) then
      Break;
  end;
end;

{ Names the frames of each module, its file read once for all of them. }
procedure NameFrames(Process: PProcess; Trace: PTrace);
var
  ModuleIndex: Integer;
  FrameIndex: Integer;
  Count: Integer;
  Module: PTraceModule;
  Addresses: array[0..UserBackTraceDepth - 1] of QWord;
  Matches: PSymbolMatch;
  Owners: array[0..UserBackTraceDepth - 1] of Integer;
begin
  Matches := PSymbolMatch(AllocateZeroedKernelMemory(UserBackTraceDepth * SizeOf(TSymbolMatch)));
  if Matches = nil then
    Exit;
  for ModuleIndex := 0 to Trace^.ModuleCount - 1 do
  begin
    Module := @Trace^.Modules[ModuleIndex];
    Count := 0;
    for FrameIndex := 0 to Trace^.FrameCount - 1 do
      if Trace^.Frames[FrameIndex].ModuleIndex = ModuleIndex then
      begin
        { A return address is named by the call before it. }
        Addresses[Count] := Trace^.Frames[FrameIndex].Pc - Module^.Base;
        if FrameIndex > 0 then
          Dec(Addresses[Count]);
        Owners[Count] := FrameIndex;
        Inc(Count);
      end;
    if Count = 0 then
      Continue;
    ZeroMemory(Matches, UserBackTraceDepth * SizeOf(TSymbolMatch));
    PrepareModule(Process, Module);
    if Module^.HasFile then
      MatchFileSymbols(Module^.ModuleFile, @Addresses[0], Count, Matches);
    MatchDynamicSymbols(Module^.Symbols, Module^.SymbolCount, Module^.Strings, Module^.StringsSize,
      @Addresses[0], Count, Matches);
    for FrameIndex := 0 to Count - 1 do
      Trace^.Frames[Owners[FrameIndex]].Symbol := Matches[FrameIndex];
  end;
  FreeKernelMemory(Matches);
end;

procedure WriteFrames(Trace: PTrace; Tag: PChar);
var
  Index: Integer;
  Frame: ^TTraceFrame;
  Module: PTraceModule;
  Readable: array[0..SymbolNameCapacity - 1] of Char;
begin
  for Index := 0 to Trace^.FrameCount - 1 do
  begin
    Frame := @Trace^.Frames[Index];
    DebugBeginMessage;
    DebugWriteTag(Tag);
    DebugWrite('  #');
    DebugWriteDecimal(Index);
    DebugWrite(' ');
    DebugWriteAddress(Frame^.Pc);
    if Frame^.ModuleIndex <> NoModule then
    begin
      Module := @Trace^.Modules[Frame^.ModuleIndex];
      DebugWrite(' ');
      DebugWrite(@Module^.Name[0]);
      DebugWrite('+0x');
      DebugWriteHex(Frame^.Pc - Module^.Base, 1);
      if Frame^.Symbol.Found then
      begin
        ReadableSymbolName(@Frame^.Symbol.Name[0], @Readable[0], SizeOf(Readable));
        DebugWrite(' ');
        DebugWrite(@Readable[0]);
        DebugWrite('+0x');
        DebugWriteHex(Frame^.Pc - Module^.Base - Frame^.Symbol.Value, 1);
      end;
    end;
    DebugWriteLine('');
    DebugEndMessage;
  end;
end;

procedure ReleaseTrace(Trace: PTrace);
var
  Index: Integer;
begin
  for Index := 0 to Trace^.ModuleCount - 1 do
  begin
    if Trace^.Modules[Index].HasFile then
      CloseModuleFile(Trace^.Modules[Index].ModuleFile);
    if Trace^.Modules[Index].DebugFrame <> nil then
      FreeKernelMemory(Trace^.Modules[Index].DebugFrame);
  end;
  FreeKernelMemory(Trace);
end;

procedure WriteUserBackTrace(Process: PProcess; Frame: PTrapFrame; Tag: PChar);
var
  Trace: PTrace;
begin
  if (Process = nil) or (Frame = nil) then
    Exit;
  Trace := PTrace(AllocateZeroedKernelMemory(SizeOf(TTrace)));
  if Trace = nil then
    Exit;
  GetUnwindArchitecture(Trace^.Architecture);
  Trace^.Memory.Read := @ReadUserMemory;
  Trace^.Memory.Context := nil;
  TakeModules(Process, Trace);
  CollectFrames(Process, Frame, Trace);
  NameFrames(Process, Trace);
  WriteFrames(Trace, Tag);
  ReleaseTrace(Trace);
end;

end.

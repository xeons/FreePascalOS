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
  What ELF programs and libraries look like on x86-64, for the image
  loader (Processes.ImageLoader) and the thread storage
  (Processes.ThreadStorage): the machine, the relocation types, and the
  thread-local storage layout.

  Thread-local storage is "variant II": the thread pointer (%fs base)
  points at the thread control block, and the TLS blocks of the program
  and its libraries lie below it, the program's nearest. A module's
  TlsOffset is the distance from its block up to the thread pointer.

      region start                                   thread pointer
      | ... library TLS blocks ... | program TLS block | control block |
}
unit Processes.Arch.ImageFormat;

{$mode objfpc}

interface

uses
  Elf64;

const
  ImageMachine = ElfMachineAmd64;
  { TLS descriptors (R_X86_64_TLSDESC) are not supported on x86-64. }
  TlsDescriptorResolverName = '';
  TlsDynamicDescriptorResolverName = '';

type
  { What a relocation does, whatever its number on this processor. }
  TRelocationKind = (
    RelocationKindNone,
    RelocationKindRelative,          { base + addend }
    RelocationKindAbsolute64,        { symbol + addend }
    RelocationKindSymbol,            { symbol (GOT entries, PLT slots) }
    RelocationKindCopy,              { the symbol's data copied here }
    RelocationKindTlsModule,         { the module id for __tls_get_addr }
    RelocationKindTlsOffset,         { the offset in the module's block }
    RelocationKindThreadPointerOffset64,
    RelocationKindThreadPointerOffset32,
    { A TLS descriptor: the resolver's address and its argument. }
    RelocationKindTlsDescriptor,
    RelocationKindUnsupported);

function ClassifyRelocation(RelocationType: LongWord): TRelocationKind;

{ Places a TLS block of BlockSize bytes, aligned to Alignment, after the
  StaticTlsSize bytes placed so far. Returns the block's TlsOffset and
  the new StaticTlsSize. }
function PlaceStaticTlsBlock(var StaticTlsSize: QWord; BlockSize, Alignment: QWord): QWord;

{ The address of a module's block minus the thread pointer. }
function TlsBlockDisplacement(TlsOffset: QWord): Int64;

{ The size of a thread's data region (TLS blocks and control block) and
  where the thread pointer is in it, for StaticTlsSize bytes of TLS
  whose largest alignment is Alignment. The region starts on a page. }
procedure LayOutThreadRegion(StaticTlsSize, Alignment: QWord; out RegionSize, ThreadPointerOffset: QWord);

implementation

uses
  Abi.SystemCalls;

function ClassifyRelocation(RelocationType: LongWord): TRelocationKind;
begin
  case RelocationType of
    RelocationNone: Result := RelocationKindNone;
    RelocationRelative: Result := RelocationKindRelative;
    Relocation64: Result := RelocationKindAbsolute64;
    RelocationGlobalData, RelocationJumpSlot: Result := RelocationKindSymbol;
    RelocationCopy: Result := RelocationKindCopy;
    RelocationTlsModule64: Result := RelocationKindTlsModule;
    RelocationTlsOffset64: Result := RelocationKindTlsOffset;
    RelocationThreadPointerOffset64: Result := RelocationKindThreadPointerOffset64;
    RelocationThreadPointerOffset32: Result := RelocationKindThreadPointerOffset32;
  else
    Result := RelocationKindUnsupported;
  end;
end;

function PlaceStaticTlsBlock(var StaticTlsSize: QWord; BlockSize, Alignment: QWord): QWord;
begin
  Result := (StaticTlsSize + BlockSize + Alignment - 1) and not (Alignment - 1);
  StaticTlsSize := Result;
end;

function TlsBlockDisplacement(TlsOffset: QWord): Int64;
begin
  Result := -Int64(TlsOffset);
end;

procedure LayOutThreadRegion(StaticTlsSize, Alignment: QWord; out RegionSize, ThreadPointerOffset: QWord);
var
  TlsAreaSize: QWord;
begin
  { Alignments are at most a page, so the thread pointer ends up aligned
    for every block. }
  TlsAreaSize := (StaticTlsSize + Alignment - 1) and not (Alignment - 1);
  RegionSize := TlsAreaSize + ThreadBlockSize;
  ThreadPointerOffset := TlsAreaSize;
end;

end.

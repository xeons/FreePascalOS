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
  AES encryption with the processor's AES instructions (AES-NI on
  x86-64; on other processors none are used yet, and Crypto.Aes falls
  back to its tables). They take the same time whatever the key and data, unlike a
  table driven implementation, so Crypto.Aes uses them whenever the
  processor has them, and the TLS library offers AES-GCM only then.

  Round keys are 16 bytes per round, round 0 first, each the four key
  schedule words in big endian order (the byte order of the state).
}
unit Crypto.AesInstructions;

{$mode objfpc}
{$ifdef CPUX86_64}
{$asmmode intel}
{$endif}

interface

function ProcessorHasAesInstructions: Boolean;

{ Encrypts one 16-byte block with RoundCount + 1 round keys. }
procedure EncryptBlockWithAesInstructions(RoundKeys: PByte; RoundCount: LongInt; Source, Destination: PByte);

implementation

{$ifdef CPUX86_64}
var
  Checked: Boolean = False;
  Available: Boolean = False;

{ CPUID leaf 1, ECX bit 25. }
function QueryAesInstructions: Boolean; assembler; nostackframe;
asm
  push rbx
  mov eax, 1
  xor ecx, ecx
  cpuid
  xor eax, eax
  bt ecx, 25
  setc al
  pop rbx
end;

function ProcessorHasAesInstructions: Boolean;
begin
  if not Checked then
  begin
    Available := QueryAesInstructions;
    Checked := True;
  end;
  Result := Available;
end;

{ System V: RDI round keys, ESI round count, RDX source, RCX
  destination. The registers that held key material are cleared. }
procedure EncryptBlockWithAesInstructions(RoundKeys: PByte; RoundCount: LongInt; Source, Destination: PByte);
  assembler; nostackframe;
asm
  movdqu xmm0, [rdx]
  movdqu xmm1, [rdi]
  pxor xmm0, xmm1
  mov eax, 1
@NextRound:
  add rdi, 16
  movdqu xmm1, [rdi]
  cmp eax, esi
  jae @LastRound
  aesenc xmm0, xmm1
  inc eax
  jmp @NextRound
@LastRound:
  aesenclast xmm0, xmm1
  movdqu [rcx], xmm0
  pxor xmm0, xmm0
  pxor xmm1, xmm1
end;
{$else}
function ProcessorHasAesInstructions: Boolean;
begin
  Result := False;
end;

procedure EncryptBlockWithAesInstructions(RoundKeys: PByte; RoundCount: LongInt; Source, Destination: PByte);
begin
  { Never called: ProcessorHasAesInstructions is False. }
end;
{$endif}

end.

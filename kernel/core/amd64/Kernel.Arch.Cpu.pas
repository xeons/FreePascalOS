{
  x86-64 processor primitives: interrupt flag control, control registers,
  model specific registers, CPUID and TLB maintenance.

  System V calling convention: arguments in RDI, RSI, RDX, RCX; results in
  RAX. Procedures are declared "assembler; nostackframe" so the compiler
  adds nothing around the instructions.
}
unit Kernel.Arch.Cpu;

{$mode objfpc}
{$asmmode intel}

interface

type
  TCpuidResult = record
    Eax: LongWord;
    Ebx: LongWord;
    Ecx: LongWord;
    Edx: LongWord;
  end;

const
  RflagsInterruptEnable = QWord(1) shl 9;

  Cr0WriteProtect = QWord(1) shl 16;
  Cr4PageGlobalEnable = QWord(1) shl 7;

  MsrExtendedFeatureEnable = $C0000080;
  EferNoExecuteEnable = QWord(1) shl 11;

  CpuidExtendedFeatures = $80000001;
  CpuidExtendedEdxNoExecute = LongWord(1) shl 20;

procedure DisableInterrupts;
procedure EnableInterrupts;
function InterruptsAreEnabled: Boolean;

{ Disables interrupts and reports whether they were enabled before, so
  the caller can put things back with RestoreInterrupts. }
function SaveAndDisableInterrupts: Boolean;
procedure RestoreInterrupts(WereEnabled: Boolean);

procedure HaltProcessor;

{ Enables interrupts and halts in one step, so an interrupt arriving
  between the two cannot be missed. }
procedure EnableInterruptsAndHalt;

{ Hint to the processor that the caller is in a spin-wait loop. }
procedure CpuRelax;

function ReadControlRegister0: QWord;
procedure WriteControlRegister0(Value: QWord);
function ReadControlRegister2: QWord;
function ReadControlRegister3: QWord;
procedure WriteControlRegister3(Value: QWord);
function ReadControlRegister4: QWord;
procedure WriteControlRegister4(Value: QWord);

{ CR8 holds the task priority: interrupts in priority classes at or below
  it are held off by the local APIC. }
function ReadTaskPriority: QWord;
procedure WriteTaskPriority(Value: QWord);

function ReadModelSpecificRegister(Register: LongWord): QWord;
procedure WriteModelSpecificRegister(Register: LongWord; Value: QWord);

procedure ExecuteCpuid(Leaf: LongWord; Subleaf: LongWord; out Registers: TCpuidResult);

procedure InvalidateTlbEntry(VirtualAddress: QWord);
procedure FlushEntireTlb;

{ The time stamp counter (cycles since reset). }
function ReadTimeStampCounter: QWord;
{ True if the processor has a hardware random number generator (RDRAND). }
function HardwareRandomIsAvailable: Boolean;
{ A random number from RDRAND; False if it failed (or is not there). }
function ReadHardwareRandom(out Value: QWord): Boolean;

function ReadStackPointer: QWord;
function ReadFramePointer: QWord;

implementation

procedure DisableInterrupts; assembler; nostackframe;
asm
  cli
end;

procedure EnableInterrupts; assembler; nostackframe;
asm
  sti
end;

function ReadFlagsRegister: QWord; assembler; nostackframe;
asm
  pushfq
  pop rax
end;

function InterruptsAreEnabled: Boolean;
begin
  Result := (ReadFlagsRegister and RflagsInterruptEnable) <> 0;
end;

function SaveAndDisableInterrupts: Boolean;
begin
  Result := InterruptsAreEnabled;
  DisableInterrupts;
end;

procedure RestoreInterrupts(WereEnabled: Boolean);
begin
  if WereEnabled then
    EnableInterrupts;
end;

procedure HaltProcessor; assembler; nostackframe;
asm
  hlt
end;

procedure EnableInterruptsAndHalt; assembler; nostackframe;
asm
  { sti only takes effect after the following instruction, so no interrupt
    can be delivered between the two. }
  sti
  hlt
end;

procedure CpuRelax; assembler; nostackframe;
asm
  pause
end;

function ReadControlRegister0: QWord; assembler; nostackframe;
asm
  mov rax, cr0
end;

procedure WriteControlRegister0(Value: QWord); assembler; nostackframe;
asm
  mov cr0, rdi
end;

function ReadControlRegister2: QWord; assembler; nostackframe;
asm
  mov rax, cr2
end;

function ReadControlRegister3: QWord; assembler; nostackframe;
asm
  mov rax, cr3
end;

procedure WriteControlRegister3(Value: QWord); assembler; nostackframe;
asm
  mov cr3, rdi
end;

function ReadControlRegister4: QWord; assembler; nostackframe;
asm
  mov rax, cr4
end;

procedure WriteControlRegister4(Value: QWord); assembler; nostackframe;
asm
  mov cr4, rdi
end;

function ReadTaskPriority: QWord; assembler; nostackframe;
asm
  { mov rax, cr8 (the inline assembler does not know CR8) }
  db $44, $0F, $20, $C0
end;

procedure WriteTaskPriority(Value: QWord); assembler; nostackframe;
asm
  mov rax, rdi
  { mov cr8, rax }
  db $44, $0F, $22, $C0
end;

function ReadModelSpecificRegister(Register: LongWord): QWord; assembler; nostackframe;
asm
  mov ecx, edi
  rdmsr
  shl rdx, 32
  or rax, rdx
end;

procedure WriteModelSpecificRegister(Register: LongWord; Value: QWord); assembler; nostackframe;
asm
  mov ecx, edi
  mov rax, rsi
  mov rdx, rsi
  shr rdx, 32
  wrmsr
end;

procedure ExecuteCpuid(Leaf: LongWord; Subleaf: LongWord; out Registers: TCpuidResult); assembler; nostackframe;
asm
  { RBX is callee saved in the System V convention. }
  push rbx
  mov r8, rdx
  mov eax, edi
  mov ecx, esi
  cpuid
  mov [r8], eax
  mov [r8 + 4], ebx
  mov [r8 + 8], ecx
  mov [r8 + 12], edx
  pop rbx
end;

function ReadTimeStampCounter: QWord; assembler; nostackframe;
asm
  rdtsc
  shl rdx, 32
  or rax, rdx
end;

function HardwareRandomIsAvailable: Boolean;
const
  CpuidRdrandBit = LongWord(1) shl 30;
var
  Registers: TCpuidResult;
begin
  ExecuteCpuid(1, 0, Registers);
  Result := (Registers.Ecx and CpuidRdrandBit) <> 0;
end;

{ RDI = where to store the value. RDRAND may fail for a moment when the
  generator is drained, so it is tried a few times. }
function RandomInstruction(Destination: PQWord): Boolean; assembler; nostackframe;
asm
  mov ecx, 10
@Retry:
  db $48, $0F, $C7, $F0 { rdrand rax }
  jc @Got
  dec ecx
  jnz @Retry
  xor eax, eax
  ret
@Got:
  mov [rdi], rax
  mov eax, 1
end;

function ReadHardwareRandom(out Value: QWord): Boolean;
begin
  Value := 0;
  Result := HardwareRandomIsAvailable and RandomInstruction(@Value);
end;

procedure InvalidateTlbEntry(VirtualAddress: QWord); assembler; nostackframe;
asm
  invlpg [rdi]
end;

procedure FlushEntireTlb; assembler; nostackframe;
asm
  mov rax, cr3
  mov cr3, rax
end;

function ReadStackPointer: QWord; assembler; nostackframe;
asm
  mov rax, rsp
end;

function ReadFramePointer: QWord; assembler; nostackframe;
asm
  mov rax, rbp
end;

end.

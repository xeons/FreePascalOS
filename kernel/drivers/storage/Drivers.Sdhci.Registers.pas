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
  The registers of an SD host controller (the SD Host Controller
  Simplified Specification, versions 2.00 and 3.00), and the SD commands
  the driver sends (the SD Physical Layer Simplified Specification).
}
unit Drivers.Sdhci.Registers;

{$mode objfpc}

interface

const
  { --- Registers (offsets in a slot's register block) --- }
  SdhciSystemAddress = $00;
  SdhciBlockSize = $04;
  SdhciBlockCount = $06;
  SdhciArgument = $08;
  SdhciTransferMode = $0C;
  SdhciCommand = $0E;
  SdhciResponse = $10;
  SdhciBufferData = $20;
  SdhciPresentState = $24;
  SdhciHostControl1 = $28;
  SdhciPowerControl = $29;
  SdhciClockControl = $2C;
  SdhciTimeoutControl = $2E;
  SdhciSoftwareReset = $2F;
  SdhciInterruptStatus = $30;
  SdhciErrorStatus = $32;
  SdhciInterruptStatusEnable = $34;
  SdhciInterruptSignalEnable = $38;
  SdhciHostControl2 = $3E;
  SdhciCapabilities = $40;
  SdhciCapabilities1 = $44;
  SdhciAdmaErrorStatus = $54;
  SdhciAdmaAddress = $58;
  SdhciAdmaAddressHigh = $5C;
  SdhciHostVersion = $FE;
  SdhciRegisterSpan = $100;

  { Block size: the SDMA boundary bits (512 KiB) above the size. }
  BlockSizeBoundary512K = $7000;

  { Transfer mode. }
  TransferDmaEnable = $0001;
  TransferBlockCountEnable = $0002;
  TransferAutoCommand12 = $0004;
  TransferRead = $0010;
  TransferMultipleBlocks = $0020;

  { Command register: response kinds and checks. }
  CommandResponseNone = $00;
  CommandResponse136 = $01;
  CommandResponse48 = $02;
  CommandResponse48Busy = $03;
  CommandCrcCheck = $08;
  CommandIndexCheck = $10;
  CommandDataPresent = $20;
  CommandTypeAbort = $C0;
  CommandIndexShift = 8;

  { Present state. }
  PresentCommandInhibit = LongWord(1) shl 0;
  PresentDataInhibit = LongWord(1) shl 1;
  PresentCardInserted = LongWord(1) shl 16;
  PresentCardStable = LongWord(1) shl 17;
  PresentWriteEnabled = LongWord(1) shl 19;

  { Host control 1. }
  HostControlFourBitBus = $02;
  HostControlHighSpeed = $04;
  HostControlDmaMask = $18;
  HostControlAdma32 = $10;

  { Power control. }
  PowerBusOn = $01;
  PowerVoltage33 = $0E;
  PowerVoltage30 = $0C;
  PowerVoltage18 = $0A;

  { Clock control. }
  ClockInternalEnable = $0001;
  ClockInternalStable = $0002;
  ClockCardEnable = $0004;

  { Timeout control: the longest (TMCLK x 2^27). }
  TimeoutLongest = $0E;

  { Software reset. }
  ResetAll = $01;
  ResetCommandLine = $02;
  ResetDataLine = $04;

  { Interrupt status (normal in the low half, errors in the high half of
    the 32-bit word at SdhciInterruptStatus). }
  InterruptCommandComplete = LongWord(1) shl 0;
  InterruptTransferComplete = LongWord(1) shl 1;
  InterruptDma = LongWord(1) shl 3;
  InterruptBufferWriteReady = LongWord(1) shl 4;
  InterruptBufferReadReady = LongWord(1) shl 5;
  InterruptCardInsertion = LongWord(1) shl 6;
  InterruptCardRemoval = LongWord(1) shl 7;
  InterruptCard = LongWord(1) shl 8;
  InterruptError = LongWord(1) shl 15;
  ErrorCommandTimeout = LongWord(1) shl 16;
  ErrorCommandCrc = LongWord(1) shl 17;
  ErrorCommandEndBit = LongWord(1) shl 18;
  ErrorCommandIndex = LongWord(1) shl 19;
  ErrorDataTimeout = LongWord(1) shl 20;
  ErrorDataCrc = LongWord(1) shl 21;
  ErrorDataEndBit = LongWord(1) shl 22;
  ErrorCurrentLimit = LongWord(1) shl 23;
  ErrorAutoCommand = LongWord(1) shl 24;
  ErrorAdma = LongWord(1) shl 25;
  ErrorsOfCommand = LongWord($000F0000);
  ErrorsOfData = LongWord($03F00000);
  ErrorsAll = LongWord($FFFF0000);
  { Everything but the card interrupt (SDIO; it is level and not
    cleared by writing it). }
  InterruptsUsed = LongWord($FFFF00FF) and not InterruptCard;

  { Host control 2. }
  HostControl2SignalVoltage18 = $0008;
  HostControl2PresetValueEnable = $8000;

  { Capabilities. }
  CapabilityBaseClockShift = 8;
  CapabilityAdma2 = LongWord(1) shl 19;
  CapabilityHighSpeed = LongWord(1) shl 21;
  CapabilityVoltage33 = LongWord(1) shl 24;
  CapabilityVoltage30 = LongWord(1) shl 25;
  CapabilityVoltage18 = LongWord(1) shl 26;

  { Host version: the specification version in the low byte. }
  SpecificationVersion200 = 1;
  SpecificationVersion300 = 2;

  { ADMA2 descriptor attributes (32-bit descriptors: attribute and
    length, then the address). }
  AdmaValid = $0001;
  AdmaEnd = $0002;
  AdmaTransfer = $0020;
  AdmaDescriptorBytes = 8;
  { What one descriptor moves at most here (its length field has 16
    bits). }
  AdmaPieceBytes = 32 * 1024;

  { --- SD commands --- }
  SdGoIdleState = 0;
  SdAllSendCid = 2;
  SdSendRelativeAddress = 3;
  SdSwitchFunction = 6;
  SdSelectCard = 7;
  SdSendInterfaceCondition = 8;
  SdSendCsd = 9;
  SdStopTransmission = 12;
  SdSendStatus = 13;
  SdSetBlockLength = 16;
  SdReadSingleBlock = 17;
  SdReadMultipleBlocks = 18;
  SdWriteSingleBlock = 24;
  SdWriteMultipleBlocks = 25;
  SdApplicationCommand = 55;
  { After SdApplicationCommand. }
  SdAppSetBusWidth = 6;
  SdAppSendOperatingCondition = 41;
  SdAppSendScr = 51;

  { CMD8's argument: 2.7-3.6 V and the check pattern. }
  InterfaceConditionArgument = $1AA;
  { ACMD41: high capacity supported, and 2.7-3.6 V. }
  OperatingConditionHighCapacity = LongWord(1) shl 30;
  OperatingConditionVoltages = LongWord($00FF8000);
  OperatingConditionReady = LongWord(1) shl 31;

  SdBlockSize = 512;

implementation

end.

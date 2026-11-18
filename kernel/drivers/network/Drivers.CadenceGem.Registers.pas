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
  The registers of the Cadence GEM (Gigabit Ethernet MAC, "cdns,macb"
  in its GEM form), as Linux's macb.h names them: the ones the
  Raspberry Pi 5's RP1 Ethernet driver (Drivers.CadenceGem) uses.
}
unit Drivers.CadenceGem.Registers;

{$mode objfpc}

interface

const
  GemRegisterBytes = $4000;

  { Network control. }
  GemNetworkControl = $0000;
  ControlReceiveEnable = LongWord(1) shl 2;
  ControlTransmitEnable = LongWord(1) shl 3;
  ControlManagementPortEnable = LongWord(1) shl 4;
  ControlClearStatistics = LongWord(1) shl 5;
  ControlTransmitStart = LongWord(1) shl 9;
  ControlTransmitHalt = LongWord(1) shl 10;

  { Network configuration. }
  GemNetworkConfiguration = $0004;
  ConfigurationSpeed100 = LongWord(1) shl 0;
  ConfigurationFullDuplex = LongWord(1) shl 1;
  ConfigurationCopyAllFrames = LongWord(1) shl 4;
  ConfigurationReceive1536 = LongWord(1) shl 8;
  ConfigurationGigabit = LongWord(1) shl 10;
  ConfigurationPauseEnable = LongWord(1) shl 13;
  ConfigurationReceiveOffsetShift = 14;
  ConfigurationReceiveOffsetMask = LongWord(3) shl 14;
  ConfigurationDiscardCheckSequence = LongWord(1) shl 17;
  ConfigurationMdcDividerShift = 18;
  ConfigurationMdcDividerMask = LongWord(7) shl 18;
  ConfigurationBusWidthShift = 21;
  ConfigurationBusWidthMask = LongWord(3) shl 21;
  ConfigurationReceiveChecksumOffload = LongWord(1) shl 24;
  { MDC = pclk / 96 (RP1's 200 MHz system clock: 2.1 MHz). }
  MdcDivider96 = 5;
  BusWidth32 = 0;
  BusWidth64 = 1;
  BusWidth128 = 2;

  GemNetworkStatus = $0008;
  StatusManagementIdle = LongWord(1) shl 2;

  { User I/O: the PHY interface. }
  GemUserIo = $000C;
  UserIoRgmii = LongWord(1) shl 0;

  { DMA configuration. }
  GemDmaConfiguration = $0010;
  DmaFixedBurstMask = $1F;
  DmaBurst16 = 16;
  DmaEndianSwapDescriptors = LongWord(1) shl 6;
  DmaEndianSwapPackets = LongWord(1) shl 7;
  DmaReceivePacketBufferFull = LongWord(3) shl 8;
  DmaTransmitPacketBufferFull = LongWord(1) shl 10;
  DmaTransmitChecksumOffload = LongWord(1) shl 11;
  DmaReceiveBufferSizeShift = 16;
  DmaReceiveBufferSizeMask = LongWord($FF) shl 16;
  { The receive buffer size is in units of 64 bytes. }
  DmaReceiveBufferUnit = 64;
  DmaExtendedReceiveDescriptors = LongWord(1) shl 28;
  DmaExtendedTransmitDescriptors = LongWord(1) shl 29;
  DmaAddress64 = LongWord(1) shl 30;

  GemTransmitStatus = $0014;
  GemReceiveQueue = $0018;
  GemTransmitQueue = $001C;
  GemReceiveStatus = $0020;
  GemInterruptStatus = $0024;
  GemInterruptEnable = $0028;
  GemInterruptDisable = $002C;
  GemInterruptMask = $0030;
  GemPhyMaintenance = $0034;
  GemReceivePartialStoreForward = $0044;
  GemAxiPipeline = $0054;
  GemInterruptModeration = $005C;
  GemSpecificAddress1Bottom = $0088;
  GemSpecificAddress1Top = $008C;
  GemModuleId = $00FC;
  GemFramesTransmitted = $0108;
  GemFramesReceived = $0158;
  GemReceiveCheckSequenceErrors = $0190;
  GemReceiveResourceErrors = $01A0;
  GemReceiveOverruns = $01A4;
  GemDesignConfiguration1 = $0280;
  GemDesignConfiguration2 = $0284;
  GemDesignConfiguration6 = $0294;
  { The upper 32 bits of every queue's descriptor addresses. }
  GemTransmitQueueHigh = $04C8;
  GemReceiveQueueHigh = $04D4;
  { Queues 1-15. }
  GemQueueTransmitFirst = $0440;
  GemQueueReceiveFirst = $0480;

  { Interrupts. }
  InterruptReceiveComplete = LongWord(1) shl 1;
  InterruptReceiveUsedRead = LongWord(1) shl 2;
  InterruptTransmitUsedRead = LongWord(1) shl 3;
  InterruptTransmitUnderrun = LongWord(1) shl 4;
  InterruptRetryLimit = LongWord(1) shl 5;
  InterruptTransmitError = LongWord(1) shl 6;
  InterruptTransmitComplete = LongWord(1) shl 7;
  InterruptReceiveOverrun = LongWord(1) shl 10;
  InterruptBusError = LongWord(1) shl 11;

  { PHY maintenance (clause 22). }
  MaintenanceDataMask = $FFFF;
  MaintenanceCodeShift = 16;
  MaintenanceCode = 2;
  MaintenanceRegisterShift = 18;
  MaintenancePhyShift = 23;
  MaintenanceOperationShift = 28;
  MaintenanceOperationWrite = 1;
  MaintenanceOperationRead = 2;
  MaintenanceStartShift = 30;
  MaintenanceStartClause22 = 1;

  { AXI pipeline. }
  AxiReadPipelineMask = $FF;
  AxiWritePipelineShift = 8;
  AxiWritePipelineMask = LongWord($FF) shl 8;
  AxiWriteFillBursts = LongWord(1) shl 16;

  { Design configuration. }
  ModuleIdShift = 16;
  ModuleIdMask = $FFF;
  ModuleIdOfGem = 2;
  Design1BusWidthShift = 25;
  Design1BusWidthMask = 7;
  Design1InterruptReadClear = LongWord(1) shl 23;
  Design6QueueMask = $FF;
  Design6DmaAddress64 = LongWord(1) shl 23;

implementation

end.

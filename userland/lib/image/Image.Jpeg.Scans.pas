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
  Walking a scan's blocks in the order the file has them.

  A scan of several components is interleaved: MCU after MCU, line by
  line, each MCU holding every component's HorizontalFactor x
  VerticalFactor blocks. A scan of one component goes block by block
  over just the blocks covering that component (each block its own
  MCU). Every RestartInterval MCUs the bits start again after a restart
  marker, with the DC predictions and the end-of-band run cleared.

  The routine given decodes one block; the walk stops early when the
  bit reader has run out of data (BitReaderExhausted), noting it in the
  state, so a cut short file keeps what was decoded and the rest stays
  as it was.
}
unit Image.Jpeg.Scans;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Jpeg.Huffman,
  Image.Jpeg.Frames;

type
  TJpegBlockRoutine = procedure(State: TJpegState; var Reader: TJpegBitReader; constref Scan: TJpegScan;
    ComponentIndex, BlockRow, BlockColumn: LongInt);

procedure WalkScan(State: TJpegState; constref Scan: TJpegScan; var Reader: TJpegBitReader;
  Routine: TJpegBlockRoutine);

implementation

procedure ResetPredictions(State: TJpegState);
var
  Index: LongInt;
begin
  for Index := 0 to State.Frame.ComponentCount - 1 do
    State.Frame.Components[Index].DcPredictor := 0;
  State.EndOfBandRun := 0;
end;

procedure WalkScan(State: TJpegState; constref Scan: TJpegScan; var Reader: TJpegBitReader;
  Routine: TJpegBlockRoutine);
var
  McuCount: Int64;
  McuIndex: Int64;
  McusPerLine: LongInt;
  McuRow: LongInt;
  McuColumn: LongInt;
  ScanComponent: LongInt;
  ComponentIndex: LongInt;
  BlockRow: LongInt;
  BlockColumn: LongInt;
begin
  ResetPredictions(State);
  if Scan.ComponentCount = 1 then
  begin
    ComponentIndex := Scan.ComponentIndices[0];
    McusPerLine := State.Frame.Components[ComponentIndex].BlocksPerLine;
    McuCount := Int64(McusPerLine) * State.Frame.Components[ComponentIndex].BlocksPerColumn;
  end
  else
  begin
    ComponentIndex := -1;
    McusPerLine := State.Frame.McusPerLine;
    McuCount := Int64(McusPerLine) * State.Frame.McusPerColumn;
  end;
  McuIndex := 0;
  while McuIndex < McuCount do
  begin
    if (State.RestartInterval > 0) and (McuIndex > 0) and (McuIndex mod State.RestartInterval = 0) then
    begin
      RestartBitReader(Reader);
      ResetPredictions(State);
    end;
    McuRow := McuIndex div McusPerLine;
    McuColumn := McuIndex mod McusPerLine;
    if ComponentIndex >= 0 then
      Routine(State, Reader, Scan, ComponentIndex, McuRow, McuColumn)
    else
      for ScanComponent := 0 to Scan.ComponentCount - 1 do
        with State.Frame.Components[Scan.ComponentIndices[ScanComponent]] do
          for BlockRow := McuRow * VerticalFactor to McuRow * VerticalFactor + VerticalFactor - 1 do
            for BlockColumn := McuColumn * HorizontalFactor to McuColumn * HorizontalFactor + HorizontalFactor - 1 do
              Routine(State, Reader, Scan, Scan.ComponentIndices[ScanComponent], BlockRow, BlockColumn);
    if BitReaderExhausted(Reader) then
    begin
      State.DataEnded := True;
      Exit;
    end;
    Inc(McuIndex);
  end;
end;

end.

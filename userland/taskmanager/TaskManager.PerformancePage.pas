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
  The Performance tab: how busy the processors have been over the last
  minute (all of them together, then each one) and how much memory was
  in use, as graphs that move on at every look; and the numbers - how
  many processes and threads there are, how long the system has run,
  and what the memory is used for.

  Everything is placed by Layout as fractions of the page in logical
  units, so it fills a large window and stays readable in a small one,
  at any scale.
}
unit TaskManager.PerformancePage;

{$mode objfpc}
{$H+}

interface

uses
  Abi.SystemCalls,
  Controls.Base,
  Controls.Window,
  Controls.Labels,
  TaskManager.Sampler,
  TaskManager.UsageGraph;

type
  TNumberRow = record
    Caption: TLabel;
    Value: TLabel;
  end;

  TPerformancePage = class(TControl)
  private
    FWindow: TControlWindow;
    FSampler: TUsageSampler;
    FAllProcessors: TUsageGraph;
    FProcessors: array[0..AbiMaximumProcessors - 1] of TUsageGraph;
    FProcessorCount: LongInt;
    FMemory: TUsageGraph;
    FNumbers: array of TNumberRow;
    procedure AddNumber(const Caption: string);
    procedure SetNumber(Index: LongInt; const Value: string);
    procedure MakeProcessorGraphs;
    procedure LayOutNumbers(Top, Width: LongInt);
  protected
    procedure Layout; override;
  public
    constructor CreatePage(AParent: TControl; Window: TControlWindow; Sampler: TUsageSampler);
    procedure Update;
    procedure TellPlaces;
  end;

implementation

uses
  SysUtils,
  Drawing.Rectangles,
  Sys.SystemUsage,
  Windowing.Connection,
  TaskManager.History,
  TaskManager.Formatting,
  TaskManager.Output;

const
  { Logical units. }
  Margin = 6;
  Gap = 6;
  NumberRowHeight = 16;
  { The numbers, in three columns of NumbersPerColumn. }
  NumbersPerColumn = 6;
  NumberColumns = 3;
  { How many processors' graphs go in one row. }
  ProcessorsPerRow = 8;

  NumberProcesses = 0;
  NumberThreads = 1;
  NumberUptime = 2;
  NumberProcessors = 3;
  NumberSwitches = 4;
  NumberTotal = 5;
  NumberInUse = 6;
  NumberFree = 7;
  NumberPrograms = 8;
  NumberProgramFiles = 9;
  NumberShared = 10;
  NumberDiskCache = 11;
  NumberKernelHeap = 12;
  NumberKernelStacks = 13;
  NumberPageTables = 14;
  NumberKernel = 15;
  NumberDrivers = 16;

constructor TPerformancePage.CreatePage(AParent: TControl; Window: TControlWindow; Sampler: TUsageSampler);
begin
  inherited Create(AParent);
  FWindow := Window;
  FSampler := Sampler;
  FAllProcessors := TUsageGraph.Create(Self);
  FAllProcessors.History := Sampler.AllProcessorsHistory;
  FAllProcessors.Text := 'CPU usage';
  FMemory := TUsageGraph.Create(Self);
  FMemory.History := Sampler.MemoryHistory;
  FMemory.LineColor := MemoryLineColor;
  FMemory.Text := 'Memory';
  AddNumber('Processes:');
  AddNumber('Threads:');
  AddNumber('Up time:');
  AddNumber('Processors:');
  AddNumber('Switches:');
  AddNumber('Memory:');
  AddNumber('In use:');
  AddNumber('Free:');
  AddNumber('Programs:');
  AddNumber('Program files:');
  AddNumber('Shared:');
  AddNumber('Disk cache:');
  AddNumber('Kernel heap:');
  AddNumber('Kernel stacks:');
  AddNumber('Page tables:');
  AddNumber('Kernel:');
  AddNumber('Drivers:');
end;

procedure TPerformancePage.AddNumber(const Caption: string);
var
  Index: LongInt;
begin
  Index := Length(FNumbers);
  SetLength(FNumbers, Index + 1);
  FNumbers[Index].Caption := TLabel.Create(Self);
  FNumbers[Index].Caption.ShowsMnemonic := False;
  FNumbers[Index].Caption.Text := Caption;
  FNumbers[Index].Value := TLabel.Create(Self);
  FNumbers[Index].Value.ShowsMnemonic := False;
end;

procedure TPerformancePage.SetNumber(Index: LongInt; const Value: string);
begin
  if FNumbers[Index].Value.Text <> Value then
    FNumbers[Index].Value.Text := Value;
end;

{ A graph for each processor that runs, made once their number is known. }
procedure TPerformancePage.MakeProcessorGraphs;
var
  Index: LongInt;
  Usage: TAbiSystemUsage;
begin
  Usage := FSampler.Usage;
  if (FProcessorCount > 0) or (Usage.ProcessorCount = 0) then
    Exit;
  FProcessorCount := Usage.ProcessorCount;
  for Index := 0 to FProcessorCount - 1 do
  begin
    FProcessors[Index] := TUsageGraph.Create(Self);
    FProcessors[Index].History := FSampler.ProcessorHistory[Index];
  end;
  Layout;
end;

procedure TPerformancePage.LayOutNumbers(Top, Width: LongInt);
var
  Index: LongInt;
  ColumnWidth: LongInt;
  CaptionWidth: LongInt;
  Left: LongInt;
  RowTop: LongInt;
begin
  ColumnWidth := (Width - 2 * Margin) div NumberColumns;
  CaptionWidth := ColumnWidth * 11 div 20;
  for Index := 0 to High(FNumbers) do
  begin
    Left := Margin + (Index div NumbersPerColumn) * ColumnWidth;
    RowTop := Top + (Index mod NumbersPerColumn) * NumberRowHeight;
    FNumbers[Index].Caption.AssignBounds(Left, RowTop, CaptionWidth, NumberRowHeight);
    FNumbers[Index].Value.AssignBounds(Left + CaptionWidth, RowTop, ColumnWidth - CaptionWidth - Gap,
      NumberRowHeight);
  end;
end;

procedure TPerformancePage.Layout;
var
  Width: LongInt;
  Height: LongInt;
  NumbersTop: LongInt;
  GraphsHeight: LongInt;
  Top: LongInt;
  Rows: LongInt;
  RowHeight: LongInt;
  Index: LongInt;
  PerRow: LongInt;
  CellWidth: LongInt;
begin
  Width := Unscaled(RectangleWidth(PixelBounds));
  Height := Unscaled(RectangleHeight(PixelBounds));
  NumbersTop := Height - Margin - NumbersPerColumn * NumberRowHeight;
  GraphsHeight := NumbersTop - Gap - Margin;
  { All the processors 40%, each one 25% (in rows), the memory the rest. }
  Top := Margin;
  FAllProcessors.AssignBounds(Margin, Top, Width - 2 * Margin, GraphsHeight * 2 div 5 - Gap);
  Top := Top + GraphsHeight * 2 div 5;
  if FProcessorCount > 0 then
  begin
    PerRow := FProcessorCount;
    if PerRow > ProcessorsPerRow then
      PerRow := ProcessorsPerRow;
    Rows := (FProcessorCount + PerRow - 1) div PerRow;
    RowHeight := GraphsHeight div 4 div Rows;
    CellWidth := (Width - 2 * Margin + Gap) div PerRow;
    for Index := 0 to FProcessorCount - 1 do
      FProcessors[Index].AssignBounds(Margin + (Index mod PerRow) * CellWidth, Top + (Index div PerRow) * RowHeight,
        CellWidth - Gap, RowHeight - Gap);
  end;
  Top := Top + GraphsHeight div 4;
  FMemory.AssignBounds(Margin, Top, Width - 2 * Margin, Margin + GraphsHeight - Top);
  LayOutNumbers(NumbersTop, Width);
  inherited Layout;
end;

procedure TPerformancePage.Update;
var
  Usage: TAbiSystemUsage;
  Index: LongInt;
  MemoryShare: LongWord;
  AllBusy: LongWord;
begin
  MakeProcessorGraphs;
  Usage := FSampler.Usage;
  AllBusy := FSampler.AllProcessorsBusy;
  MemoryShare := FSampler.MemoryInUseTenths;
  FAllProcessors.Text := 'CPU usage ' + FormatPercent(AllBusy);
  FAllProcessors.Invalidate;
  for Index := 0 to FProcessorCount - 1 do
  begin
    FProcessors[Index].Text := 'CPU ' + IntToStr(Index) + '  ' + FormatPercent(NewestSample(FSampler.ProcessorHistory[Index]^));
    FProcessors[Index].Invalidate;
  end;
  FMemory.Text := 'Memory ' + FormatPercent(MemoryShare) + '  (' + FormatBytes(UsedMemory(Usage)) + ' of ' +
    FormatBytes(Usage.TotalMemory) + ')';
  FMemory.Invalidate;
  SetNumber(NumberProcesses, IntToStr(Usage.ProcessCount));
  SetNumber(NumberThreads, IntToStr(Usage.ThreadCount));
  SetNumber(NumberUptime, FormatDuration(Usage.UptimeNanoseconds div 1000000000));
  SetNumber(NumberProcessors, IntToStr(FSampler.ProcessorCount));
  SetNumber(NumberSwitches, IntToStr(Usage.ContextSwitches));
  SetNumber(NumberTotal, FormatBytes(Usage.TotalMemory));
  SetNumber(NumberInUse, FormatBytes(UsedMemory(Usage)));
  SetNumber(NumberFree, FormatBytes(Usage.FreeMemory));
  SetNumber(NumberPrograms, FormatBytes(Usage.UserMemory));
  SetNumber(NumberProgramFiles, FormatBytes(Usage.ProgramImageMemory));
  SetNumber(NumberShared, FormatBytes(Usage.SectionMemory));
  SetNumber(NumberDiskCache, FormatBytes(Usage.BlockCacheMemory));
  SetNumber(NumberKernelHeap, FormatBytes(Usage.KernelHeapMemory));
  SetNumber(NumberKernelStacks, FormatBytes(Usage.KernelStackMemory));
  SetNumber(NumberPageTables, FormatBytes(Usage.PageTableMemory));
  SetNumber(NumberKernel, FormatBytes(Usage.KernelImageMemory));
  SetNumber(NumberDrivers, FormatBytes(Usage.DriverMemory));
  if Parent.Visible then
    Say('performance cpu ' + IntToStr((AllBusy + 5) div 10) + ' memory ' + IntToStr((MemoryShare + 5) div 10) +
      ' processes ' + IntToStr(Usage.ProcessCount) + ' threads ' + IntToStr(Usage.ThreadCount));
end;

{ "graph NAME LEFT TOP WIDTH HEIGHT" in screen pixels, for a test that
  compares what the graphs show from one moment to the next. }
procedure TPerformancePage.TellPlaces;
var
  GraphBounds: TRectangle;
begin
  FWindow.PrepareToReceive;
  GraphBounds := FAllProcessors.PixelBounds;
  Say(Format('graph cpu %d %d %d %d', [Scaled(FWindow.ScreenLeft) + GraphBounds.Left, Scaled(FWindow.ScreenTop) +
    GraphBounds.Top, RectangleWidth(GraphBounds), RectangleHeight(GraphBounds)]));
  GraphBounds := FMemory.PixelBounds;
  Say(Format('graph memory %d %d %d %d', [Scaled(FWindow.ScreenLeft) + GraphBounds.Left, Scaled(FWindow.ScreenTop) +
    GraphBounds.Top, RectangleWidth(GraphBounds), RectangleHeight(GraphBounds)]));
end;

end.

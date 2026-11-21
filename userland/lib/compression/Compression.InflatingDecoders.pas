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
  TInflatingDecoder: a TInflater (raw deflate, zlib or gzip) behind the
  TStreamingDecoder interface, so it can stand with the brotli and zstd
  decoders. Inflater gives the TInflater itself (the gzip header, the
  member count).
}
unit Compression.InflatingDecoders;

{$mode objfpc}
{$H+}

interface

uses
  Compression.Formats,
  Compression.Inflater,
  Compression.StreamingDecoders;

type
  TInflatingDecoder = class(TStreamingDecoder)
  private
    FInflater: TInflater;
  protected
    function GetFinished: Boolean; override;
    function GetInputRemaining: SizeInt; override;
  public
    constructor Create(Format: TCompressionFormat);
    destructor Destroy; override;
    procedure Reset; override;
    procedure SetInput(Data: Pointer; Count: SizeInt); override;
    function Decompress(Output: Pointer; Capacity: SizeInt; out Written: SizeInt): TDecompressResult; override;
    property Inflater: TInflater read FInflater;
  end;

implementation

constructor TInflatingDecoder.Create(Format: TCompressionFormat);
begin
  inherited Create;
  FInflater := TInflater.Create(Format);
end;

destructor TInflatingDecoder.Destroy;
begin
  FInflater.Free;
  inherited Destroy;
end;

procedure TInflatingDecoder.Reset;
begin
  FInflater.Reset;
  FError := FInflater.Error;
  FTotalOutput := 0;
end;

procedure TInflatingDecoder.SetInput(Data: Pointer; Count: SizeInt);
begin
  FInflater.SetInput(Data, Count);
end;

function TInflatingDecoder.GetFinished: Boolean;
begin
  Result := FInflater.Finished;
end;

function TInflatingDecoder.GetInputRemaining: SizeInt;
begin
  Result := FInflater.InputRemaining;
end;

function TInflatingDecoder.Decompress(Output: Pointer; Capacity: SizeInt; out Written: SizeInt): TDecompressResult;
begin
  case FInflater.Decompress(Output, Capacity, Written) of
    InflateNeedsInput: Result := DecompressNeedsInput;
    InflateOutputFull: Result := DecompressOutputFull;
    InflateFinished: Result := DecompressFinished;
  else
    Result := DecompressFailed;
  end;
  FError := FInflater.Error;
  FTotalOutput := FInflater.TotalOutput;
end;

end.

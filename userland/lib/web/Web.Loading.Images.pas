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
  <img> loading (HTML Standard 4.8.4.3 "update the image data"):

  - The source is chosen by Web.Loading.Srcset from srcset, sizes, src
    and the <picture> sources for the device pixel ratio of the sink's
    media environment; a change of any of them, of the environment
    (EnvironmentChanged) or of the element's place starts over when the
    choice differs.
  - The fetch: destination image, no-cors unless crossorigin, its
    referrerpolicy and fetchpriority, sniffed in the image context. The
    first images of a document get the urgency of visible ones.
  - Decoding (libimage, EXIF orientation applied, colours to sRGB) runs
    on a worker thread; the result comes back as a task. SVG files are
    found by their content (libsvg's codec in libimage's registry) and
    come back as scalable images, never scaled down: the painter draws
    them again at the size shown. Images much
    larger than needed (DownscaleFactor times the width and height
    attributes at the device pixel ratio, or MaximumImageSide) are
    scaled down there, so a huge photo shown small does not keep its
    full pixels. The natural size given to the sink is the original's
    divided by the chosen density.
  - load or error fires at the element (DOM manipulation task source);
    the load event of the document waits for both fetch and decode.
  - loading=lazy images wait until LoadLazyImage (layout: near the
    viewport) or the document's load event, and do not delay it.
  - An img outside the document (new Image(), one removed while it
    loads) loads too and gets its load or error event; its state is
    dropped once that is decided, so nothing keeps the element alive
    after it (inserted later, it loads again, from the HTTP cache).
}
unit Web.Loading.Images;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Url.Records,
  Image.Model,
  Web.Dom,
  Web.Loading.Contexts,
  Web.Loading.BufferedFetches,
  Web.Loading.Preloads,
  Web.Loading.ResourceSink;

type
  TImageLoader = class;

  TImageState = class
  public
    Element: TElement;
    Key: string;
    Density: Double;
    Fetch: TBufferedFetch;
    Generation: QWord;
    Decoding: Boolean;
    Delaying: Boolean;
    Lazy: Boolean;
    destructor Destroy; override;
  end;

  TImageLoader = class
  private
    FContext: TLoadingContext;
    FPreloads: TPreloadCache;
    FStates: TList;
    FNextGeneration: QWord;
    FStartedCount: Integer;
    FDecoders: TList;
    { Decodes waiting for one of the MaximumDecoders threads, and how
      many run (each ends with one DecodeDone). }
    FPendingDecodes: TList;
    FRunningDecodes: Integer;
    FDecoderLock: TRTLCriticalSection;
    FLoadEventFired: Boolean;
    function StateOf(Element: TElement): TImageState;
    procedure Start(State: TImageState; const Url: TUrlRecord);
    procedure FetchComplete(Fetch: TBufferedFetch; Success: Boolean);
    procedure DecodeDone(Data: TObject);
    procedure Fail(State: TImageState);
    procedure DropIfDetached(State: TImageState);
    procedure EndDelay(State: TImageState);
    procedure FireElementEvent(Element: TElement; const Name: string);
    procedure ReapDecoders;
    procedure StartDecode(const Bytes: TBytes; Generation: QWord; MaximumWidth, MaximumHeight: Integer);
    procedure StartPendingDecodes;
    procedure Update(Element: TElement; Force: Boolean);
    function NeededSide(Element: TElement; Attribute: LongWord; Ratio: Double): Integer;
  public
    constructor Create(Context: TLoadingContext; Preloads: TPreloadCache);
    destructor Destroy; override;
    { An img connected, or one of its attributes (or picture sources)
      changed. }
    procedure ImageChanged(Element: TElement);
    procedure ImageRemoved(Element: TElement);
    { The viewport or the pixel ratio changed: choices are made again. }
    procedure EnvironmentChanged;
    procedure LoadLazyImage(Element: TElement);
    { The document's load event fired: lazy images load now. }
    procedure LoadEventFired;
    function PendingCount: Integer;
  end;

implementation

uses
  Url.Parser,
  Image.Errors,
  Image.Files,
  Image.Scaling,
  Image.StandardCodecs,
  Image.Scalable,
  Svg.Images,
  Web.Atoms,
  Web.EventLoop.Tasks,
  Web.Fetch.Requests,
  Web.Navigation.Events,
  Web.Loading.Priorities,
  Web.Loading.Srcset;

const
  VisibleImageCount = 6;
  { Images decoded at once, each on a thread of its own; the others
    wait their turn. }
  MaximumDecoders = 3;

type
  TDecodeJob = class(TThread)
  private
    FLoader: TImageLoader;
    FBytes: TBytes;
    FGeneration: QWord;
    FMaximumWidth, FMaximumHeight: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(Loader: TImageLoader; const Bytes: TBytes; Generation: QWord; MaximumWidth,
      MaximumHeight: Integer);
  end;

  TPendingDecode = class
  public
    Bytes: TBytes;
    Generation: QWord;
    MaximumWidth, MaximumHeight: Integer;
  end;

  TDecodedImage = class
  public
    Generation: QWord;
    Image: TImage;
    OriginalWidth, OriginalHeight: Integer;
    Downscaled: Boolean;
    destructor Destroy; override;
  end;

  TImageEvent = class
  public
    Element: TElement;
    Name: string;
    destructor Destroy; override;
  end;

  TImageEventFirer = class
  public
    procedure Fire(Data: TObject);
  end;

var
  ImageEventFirer: TImageEventFirer;

destructor TImageEvent.Destroy;
begin
  Element.EndPendingActivity;
  inherited Destroy;
end;

procedure TImageEventFirer.Fire(Data: TObject);
begin
  FireEvent(TImageEvent(Data).Element, TImageEvent(Data).Name);
end;

destructor TDecodedImage.Destroy;
begin
  Image.Free;
  inherited Destroy;
end;

destructor TImageState.Destroy;
begin
  if Fetch <> nil then
  begin
    Fetch.Cancel;
    Fetch.Free;
  end;
  Element.EndPendingActivity;
  inherited Destroy;
end;

{ Decodes and, when asked, scales down; the result is posted back. }
function DecodeImageBytes(const Bytes: TBytes; MaximumWidth, MaximumHeight: Integer; Generation: QWord): TDecodedImage;
var
  Image, Scaled: TImage;
  Reason: TImageErrorReason;
begin
  Result := TDecodedImage.Create;
  Result.Generation := Generation;
  if not TryLoadImage(Bytes, Image, Reason, [ImageLoadApplyOrientation, ImageLoadConvertToSrgb]) then
    Exit;
  Result.OriginalWidth := Image.Width;
  Result.OriginalHeight := Image.Height;
  if Image is TScalableImage then
  begin
    Result.Image := Image;
    Exit;
  end;
  if (MaximumWidth > 0) and (MaximumHeight > 0) and ((Image.Width > MaximumWidth) or (Image.Height > MaximumHeight)) then
  begin
    try
      Scaled := ThumbnailImage(Image, MaximumWidth, MaximumHeight);
      Image.Free;
      Image := Scaled;
      Result.Downscaled := True;
    except
      on EImageError do;
    end;
  end;
  Result.Image := Image;
end;

constructor TDecodeJob.Create(Loader: TImageLoader; const Bytes: TBytes; Generation: QWord; MaximumWidth,
  MaximumHeight: Integer);
begin
  FLoader := Loader;
  FBytes := Bytes;
  FGeneration := Generation;
  FMaximumWidth := MaximumWidth;
  FMaximumHeight := MaximumHeight;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TDecodeJob.Execute;
var
  Decoded: TDecodedImage;
begin
  try
    Decoded := DecodeImageBytes(FBytes, FMaximumWidth, FMaximumHeight, FGeneration);
  except
    Decoded := TDecodedImage.Create;
    Decoded.Generation := FGeneration;
  end;
  FBytes := nil;
  FLoader.FContext.Loop.PostMethod(@FLoader.DecodeDone, Decoded, TaskSourceDomManipulation, FLoader);
end;

constructor TImageLoader.Create(Context: TLoadingContext; Preloads: TPreloadCache);
begin
  inherited Create;
  FContext := Context;
  FPreloads := Preloads;
  FStates := TList.Create;
  FDecoders := TList.Create;
  FPendingDecodes := TList.Create;
  InitCriticalSection(FDecoderLock);
  RegisterStandardImageCodecs;
  RegisterSvgImageCodec;
end;

destructor TImageLoader.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FDecoders.Count - 1 do
  begin
    TThread(FDecoders[Index]).WaitFor;
    TThread(FDecoders[Index]).Free;
  end;
  FDecoders.Free;
  for Index := 0 to FPendingDecodes.Count - 1 do
    TPendingDecode(FPendingDecodes[Index]).Free;
  FPendingDecodes.Free;
  FContext.Loop.DiscardTasks(Self);
  for Index := 0 to FStates.Count - 1 do
    TImageState(FStates[Index]).Free;
  FStates.Free;
  DoneCriticalSection(FDecoderLock);
  inherited Destroy;
end;

function TImageLoader.StateOf(Element: TElement): TImageState;
var
  Index: Integer;
begin
  for Index := 0 to FStates.Count - 1 do
    if TImageState(FStates[Index]).Element = Element then
      Exit(TImageState(FStates[Index]));
  Result := nil;
end;

procedure TImageLoader.FireElementEvent(Element: TElement; const Name: string);
var
  Item: TImageEvent;
begin
  Item := TImageEvent.Create;
  Item.Element := Element;
  Element.BeginPendingActivity;
  Item.Name := Name;
  FContext.Loop.QueueTask(TDataTask.Create(@ImageEventFirer.Fire, Item), TaskSourceDomManipulation, FContext);
end;

procedure TImageLoader.EndDelay(State: TImageState);
begin
  if State.Delaying then
  begin
    State.Delaying := False;
    FContext.UndelayLoad;
  end;
end;

procedure TImageLoader.ImageChanged(Element: TElement);
begin
  Update(Element, False);
end;

procedure TImageLoader.Update(Element: TElement; Force: Boolean);
var
  State: TImageState;
  Choice: TImageSourceChoice;
  Url: TUrlRecord;
  Key: string;
  Lazy: Boolean;
begin
  if not FContext.Settings.LoadImages then
    Exit;
  State := StateOf(Element);
  Choice := SelectImageSource(Element, FContext.Sink.MediaEnvironment);
  if State = nil then
  begin
    State := TImageState.Create;
    State.Element := Element;
    Element.BeginPendingActivity;
    FStates.Add(State);
  end;
  if not Choice.Found or (Choice.Url = '') or not FContext.ResolveUrl(Choice.Url, Url) then
  begin
    if State.Key = '' then
    begin
      if (State.Fetch = nil) and not State.Decoding then
        DropIfDetached(State);
      Exit;
    end;
    Inc(FNextGeneration);
    State.Generation := FNextGeneration;
    State.Key := '';
    if State.Fetch <> nil then
    begin
      State.Fetch.Cancel;
      FreeAndNil(State.Fetch);
    end;
    EndDelay(State);
    FContext.Sink.ImageRemoved(Element);
    if Element.HasAttributeAtom(AtomSrc) or Element.HasAttributeAtom(AtomSrcset) then
      FireElementEvent(Element, 'error');
    State.Decoding := False;
    DropIfDetached(State);
    Exit;
  end;
  Key := SerializeUrl(Url) + ' ' + Element.AttributeValueOf(AtomCrossorigin);
  if (Key = State.Key) and not Force and not State.Lazy then
    Exit;
  State.Key := Key;
  State.Density := Choice.Density;
  Lazy := (AsciiLowerCase(Element.AttributeValueOf(Atomize('loading'))) = 'lazy') and not FLoadEventFired and
    not Force;
  State.Lazy := Lazy;
  if Lazy then
    Exit;
  Start(State, Url);
end;

procedure TImageLoader.Start(State: TImageState; const Url: TUrlRecord);
var
  Request: TFetchRequest;
  Claimed: TBufferedFetch;
  Kind: TResourceKind;
begin
  Inc(FNextGeneration);
  State.Generation := FNextGeneration;
  if State.Fetch <> nil then
  begin
    State.Fetch.Cancel;
    FreeAndNil(State.Fetch);
  end;
  if not State.Delaying and not FLoadEventFired then
  begin
    State.Delaying := True;
    FContext.DelayLoad;
  end;
  if not State.Element.HasAttributeAtom(AtomCrossorigin) and
     FPreloads.Claim(Url, DestinationImage, @FetchComplete, Claimed) then
  begin
    State.Fetch := Claimed;
    Claimed.Data := State;
    Claimed.Tag := PtrInt(State.Generation);
    Exit;
  end;
  Request := FContext.NewRequest(Url, DestinationImage, FetchModeNoCors, FetchCredentialsSameOrigin);
  FContext.ApplyCorsSettings(Request, State.Element, FetchModeNoCors);
  FContext.ApplyReferrerPolicyAttribute(Request, State.Element);
  Request.InitiatorType := 'img';
  Request.SniffContent := True;
  Inc(FStartedCount);
  if FStartedCount <= VisibleImageCount then
    Kind := ResourceVisibleImage
  else
    Kind := ResourceImage;
  Request.Priority := PriorityFor(Kind, FetchPriorityFromAttribute(State.Element.AttributeValueOf(
    Atomize('fetchpriority'))));
  State.Fetch := TBufferedFetch.Create(@FetchComplete);
  State.Fetch.Data := State;
  State.Fetch.Tag := PtrInt(State.Generation);
  State.Fetch.Start(FContext.Fetcher, Request, FContext);
end;

function TImageLoader.NeededSide(Element: TElement; Attribute: LongWord; Ratio: Double): Integer;
var
  Value: Integer;
begin
  Result := FContext.Settings.MaximumImageSide;
  Value := StrToIntDef(Trim(Element.AttributeValueOf(Attribute)), 0);
  if Value > 0 then
    if Round(Value * Ratio * FContext.Settings.DownscaleFactor) < Result then
      Result := Round(Value * Ratio * FContext.Settings.DownscaleFactor);
end;

procedure TImageLoader.FetchComplete(Fetch: TBufferedFetch; Success: Boolean);
var
  State: TImageState;
  Bytes: TBytes;
  Body: string;
  Ratio: Double;
  MaximumWidth, MaximumHeight: Integer;
  Decoded: TDecodedImage;
begin
  State := TImageState(Fetch.Data);
  State.Fetch := nil;
  if (FStates.IndexOf(State) < 0) or (QWord(Fetch.Tag) <> State.Generation) then
  begin
    Fetch.Free;
    Exit;
  end;
  Body := Fetch.Body;
  Fetch.Free;
  if not Success or (Body = '') then
  begin
    Fail(State);
    Exit;
  end;
  Bytes := nil;
  SetLength(Bytes, Length(Body));
  Move(Body[1], Bytes[0], Length(Body));
  Ratio := FContext.Sink.MediaEnvironment.Resolution;
  if Ratio <= 0 then
    Ratio := 1;
  MaximumWidth := NeededSide(State.Element, AtomWidth, Ratio);
  MaximumHeight := NeededSide(State.Element, AtomHeight, Ratio);
  State.Decoding := True;
  if FContext.Settings.DecodeImagesOnThreads then
  begin
    StartDecode(Bytes, State.Generation, MaximumWidth, MaximumHeight)
  end
  else
  begin
    try
      Decoded := DecodeImageBytes(Bytes, MaximumWidth, MaximumHeight, State.Generation);
    except
      Decoded := TDecodedImage.Create;
      Decoded.Generation := State.Generation;
    end;
    FContext.Loop.QueueTask(TDataTask.Create(@DecodeDone, Decoded), TaskSourceDomManipulation, Self);
  end;
end;

procedure TImageLoader.StartDecode(const Bytes: TBytes; Generation: QWord; MaximumWidth, MaximumHeight: Integer);
var
  Pending: TPendingDecode;
  Decoded: TDecodedImage;
begin
  ReapDecoders;
  if FRunningDecodes >= MaximumDecoders then
  begin
    Pending := TPendingDecode.Create;
    Pending.Bytes := Bytes;
    Pending.Generation := Generation;
    Pending.MaximumWidth := MaximumWidth;
    Pending.MaximumHeight := MaximumHeight;
    FPendingDecodes.Add(Pending);
    Exit;
  end;
  try
    FDecoders.Add(TDecodeJob.Create(Self, Bytes, Generation, MaximumWidth, MaximumHeight));
    Inc(FRunningDecodes);
  except
    { No thread to be had: decoded here instead. }
    try
      Decoded := DecodeImageBytes(Bytes, MaximumWidth, MaximumHeight, Generation);
    except
      Decoded := TDecodedImage.Create;
      Decoded.Generation := Generation;
    end;
    Inc(FRunningDecodes);
    FContext.Loop.QueueTask(TDataTask.Create(@DecodeDone, Decoded), TaskSourceDomManipulation, Self);
  end;
end;

procedure TImageLoader.StartPendingDecodes;
var
  Pending: TPendingDecode;
begin
  while (FPendingDecodes.Count > 0) and (FRunningDecodes < MaximumDecoders) do
  begin
    Pending := TPendingDecode(FPendingDecodes[0]);
    FPendingDecodes.Delete(0);
    StartDecode(Pending.Bytes, Pending.Generation, Pending.MaximumWidth, Pending.MaximumHeight);
    Pending.Free;
  end;
end;

procedure TImageLoader.ReapDecoders;
var
  Index: Integer;
begin
  for Index := FDecoders.Count - 1 downto 0 do
    if TThread(FDecoders[Index]).Finished then
    begin
      TThread(FDecoders[Index]).WaitFor;
      TThread(FDecoders[Index]).Free;
      FDecoders.Delete(Index);
    end;
end;

procedure TImageLoader.DecodeDone(Data: TObject);
var
  Decoded: TDecodedImage;
  State: TImageState;
  Index: Integer;
  Info: TLoadedImageInfo;
  Image: TImage;
begin
  Decoded := TDecodedImage(Data);
  if FRunningDecodes > 0 then
    Dec(FRunningDecodes);
  StartPendingDecodes;
  State := nil;
  for Index := 0 to FStates.Count - 1 do
    if TImageState(FStates[Index]).Generation = Decoded.Generation then
      State := TImageState(FStates[Index]);
  if State = nil then
    Exit;
  State.Decoding := False;
  if Decoded.Image = nil then
  begin
    Fail(State);
    Exit;
  end;
  Info := Default(TLoadedImageInfo);
  Info.Density := State.Density;
  Info.NaturalWidth := Decoded.OriginalWidth / State.Density;
  Info.NaturalHeight := Decoded.OriginalHeight / State.Density;
  Info.CurrentUrl := Copy(State.Key, 1, Pos(' ', State.Key) - 1);
  Info.Downscaled := Decoded.Downscaled;
  Image := Decoded.Image;
  Decoded.Image := nil;
  if State.Element.IsConnected then
    FContext.Sink.ImageLoaded(State.Element, Image, Info)
  else
    Image.Free;
  FireElementEvent(State.Element, 'load');
  EndDelay(State);
  DropIfDetached(State);
end;

procedure TImageLoader.Fail(State: TImageState);
begin
  if State.Element.IsConnected then
    FContext.Sink.ImageFailed(State.Element);
  FireElementEvent(State.Element, 'error');
  EndDelay(State);
  DropIfDetached(State);
end;

{ An image outside the document whose outcome is known: the event task
  holds the element now, the state need not. }
procedure TImageLoader.DropIfDetached(State: TImageState);
begin
  if State.Element.IsConnected then
    Exit;
  FStates.Remove(State);
  FContext.Sink.ImageRemoved(State.Element);
  State.Free;
end;

procedure TImageLoader.ImageRemoved(Element: TElement);
var
  State: TImageState;
begin
  State := StateOf(Element);
  if State = nil then
    Exit;
  FContext.Sink.ImageRemoved(Element);
  { Still loading: it goes on, and ends with its event. }
  if (State.Fetch <> nil) or State.Decoding then
    Exit;
  EndDelay(State);
  FStates.Remove(State);
  State.Free;
end;

procedure TImageLoader.EnvironmentChanged;
var
  Index: Integer;
  Elements: array of TElement;
begin
  Elements := nil;
  SetLength(Elements, FStates.Count);
  for Index := 0 to FStates.Count - 1 do
    Elements[Index] := TImageState(FStates[Index]).Element;
  for Index := 0 to High(Elements) do
    Update(Elements[Index], False);
end;

procedure TImageLoader.LoadLazyImage(Element: TElement);
var
  State: TImageState;
begin
  State := StateOf(Element);
  if (State <> nil) and State.Lazy then
    Update(Element, True);
end;

procedure TImageLoader.LoadEventFired;
var
  Index: Integer;
  Lazy: array of TElement;
begin
  FLoadEventFired := True;
  Lazy := nil;
  for Index := 0 to FStates.Count - 1 do
    if TImageState(FStates[Index]).Lazy then
    begin
      SetLength(Lazy, Length(Lazy) + 1);
      Lazy[High(Lazy)] := TImageState(FStates[Index]).Element;
    end;
  for Index := 0 to High(Lazy) do
    Update(Lazy[Index], True);
end;

function TImageLoader.PendingCount: Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to FStates.Count - 1 do
    if (TImageState(FStates[Index]).Fetch <> nil) or TImageState(FStates[Index]).Decoding then
      Inc(Result);
end;

initialization
  ImageEventFirer := TImageEventFirer.Create;

finalization
  ImageEventFirer.Free;

end.

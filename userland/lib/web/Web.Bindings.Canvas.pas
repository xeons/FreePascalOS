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
  bindings/Canvas.webidl: the canvas element's getContext, toDataURL
  and transferControlToOffscreen; the 2D context's mixins (shared by
  CanvasRenderingContext2D and OffscreenCanvasRenderingContext2D, whose
  wrappers hold their TCanvasContext2D through a handle); Path2D (the
  CanvasPath mixin works on either); CanvasGradient, CanvasPattern,
  TextMetrics, ImageData, ImageBitmap, ImageBitmapRenderingContext and
  OffscreenCanvas. Attribute setters ignore values the standard says to
  ignore (non-finite numbers, unknown operators, colours that do not
  parse); the drawing is Web.Canvas.Context2D's.
}
unit Web.Bindings.Canvas;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Web.Bindings.Types;

{$I Web.Bindings.Canvas.Members.inc}

implementation

uses
  SysUtils,
  Math,
  Js.Objects,
  Js.Operations,
  Js.Conversions,
  Js.ArrayBuffers,
  Js.Functions,
  Drawing.Colors,
  Drawing.Transforms,
  Drawing.Rasterizer,
  Drawing.Stroking,
  Drawing.Paths,
  Drawing.Compositing,
  Image.Model,
  Image.Scaling,
  Svg.PathData,
  Css.Tokens,
  Css.Tokenizer,
  Css.Units,
  Web.Atoms,
  Web.Dom,
  Web.Dom.Exceptions,
  Web.Bindings.Context,
  Web.Canvas.Shared,
  Web.Canvas.Surfaces,
  Web.Canvas.Paths,
  Web.Canvas.Styles,
  Web.Canvas.Fonts,
  Web.Canvas.Text,
  Web.Canvas.Filters,
  Web.Canvas.State,
  Web.Canvas.Context2D,
  Web.Canvas.Elements,
  Web.Canvas.Encoding,
  Web.Canvas.ScriptObjects;

{ ---- helpers ---- }

function Context(const Call: TBindingCall): TBindingContext; inline;
begin
  Result := TBindingContext(Call.Context);
end;

function Rendering(const Call: TBindingCall): TCanvasContext2D;
var
  Shared: TCanvasSharedObject;
begin
  Shared := SharedOf(Call.Target);
  if not (Shared is TCanvasContext2D) then
    raise EBindingTypeError.Create('Illegal invocation');
  Result := TCanvasContext2D(Shared);
end;

function StateOf(const Call: TBindingCall): PCanvasDrawingState; inline;
begin
  Result := Rendering(Call).StateRef;
end;

function Finite(Value: Double): Boolean; inline;
begin
  Result := not IsNan(Value) and not IsInfinite(Value);
end;

function FillRuleOf(const Text: string): TFillRule;
begin
  if Text = 'evenodd' then
    Result := FillRuleEvenOdd
  else
    Result := FillRuleNonZero;
end;

function NumberValue(Value: Double): TJsValue; inline;
begin
  Result := JsNumber(Value);
end;

function GlobalConstructor(Ctx: TBindingContext; const Name: string): TJsValue;
begin
  Result := Ctx.Engine.GlobalObject.GetValue(Ctx.Engine.Realm, Ctx.Engine.Realm.Intern(Name));
  if not JsIsConstructor(Result) then
    Result := JsUndefined;
end;

function ScriptNumber(Ctx: TBindingContext; Value: TJsValue): Double;
begin
  if not ToDouble(Ctx.Engine.Realm, Value, Result) then
    raise EBindingPendingException.Create('');
end;

function PropertyOf(Ctx: TBindingContext; Target: TJsValue; const Name: string): TJsValue;
begin
  Result := GetProperty(Ctx.Engine.Realm, Target, Ctx.Engine.Realm.Intern(Name));
  if Result = JsException then
    raise EBindingPendingException.Create('');
end;

{ A DOMMatrix2DInit after "validate and fixup (2D)": the six numbers. }
function MatrixFromInit(const Init: TBindingValue): TAffineTransform;
var
  Values: array[0..11] of Double;
  Present: array[0..11] of Boolean;
  Index: Integer;

  procedure Pair(Short, Long: Integer; Default: Double);
  begin
    if Present[Short] and Present[Long] and (Values[Short] <> Values[Long]) and
       not (IsNan(Values[Short]) and IsNan(Values[Long])) then
      raise EBindingTypeError.Create('The matrix members do not match');
    if not Present[Short] then
    begin
      if Present[Long] then
        Values[Short] := Values[Long]
      else
        Values[Short] := Default;
    end;
  end;

begin
  for Index := 0 to 11 do
  begin
    Present[Index] := (Index < Length(Init.Items)) and (Init.Items[Index].Kind <> bvMissing);
    if Present[Index] then
      Values[Index] := Init.Items[Index].Number
    else
      Values[Index] := 0;
  end;
  Pair(DOMMatrix2DInit_a, DOMMatrix2DInit_m11, 1);
  Pair(DOMMatrix2DInit_b, DOMMatrix2DInit_m12, 0);
  Pair(DOMMatrix2DInit_c, DOMMatrix2DInit_m21, 0);
  Pair(DOMMatrix2DInit_d, DOMMatrix2DInit_m22, 1);
  Pair(DOMMatrix2DInit_e, DOMMatrix2DInit_m41, 0);
  Pair(DOMMatrix2DInit_f, DOMMatrix2DInit_m42, 0);
  Result := MakeTransform(Values[DOMMatrix2DInit_a], Values[DOMMatrix2DInit_b], Values[DOMMatrix2DInit_c],
    Values[DOMMatrix2DInit_d], Values[DOMMatrix2DInit_e], Values[DOMMatrix2DInit_f]);
end;

function TransformFinite(const T: TAffineTransform): Boolean;
begin
  Result := Finite(T.A) and Finite(T.B) and Finite(T.C) and Finite(T.D) and Finite(T.E) and Finite(T.F);
end;

function SurfaceCurrentColor(Rendering_: TCanvasContext2D): TColor;
begin
  if Rendering_.Surface <> nil then
    Result := Rendering_.Surface.CurrentColor
  else
    Result := ColorBlack;
end;

{ A length in CSS pixels (letterSpacing, wordSpacing); False when Text
  is not one. }
function ParseSpacing(const Text: string; FontSize: Double; out Pixels: Double): Boolean;
var
  Tokens: TCssTokenArray;
  Index, Found: Integer;
  UnitValue: TCssUnit;
begin
  Result := False;
  Pixels := 0;
  Tokens := TokenizeCss(Text);
  Found := -1;
  for Index := 0 to High(Tokens) do
    case Tokens[Index].Kind of
      tkWhitespace, tkEof: ;
    else
      if Found >= 0 then
        Exit;
      Found := Index;
    end;
  if Found < 0 then
    Exit;
  if (Tokens[Found].Kind = tkNumber) and (Tokens[Found].Number = 0) then
    Exit(True);
  if Tokens[Found].Kind <> tkDimension then
    Exit;
  UnitValue := UnitByName(LowerCase(Tokens[Found].Text));
  if IsAbsoluteLength(UnitValue) then
    Pixels := Tokens[Found].Number * CanonicalFactor(UnitValue)
  else if UnitValue in [cuEm, cuRem] then
    Pixels := Tokens[Found].Number * FontSize
  else
    Exit;
  Result := True;
end;

{ ---- HTMLCanvasElement ---- }

function CanvasElement(const Call: TBindingCall): TElement; inline;
begin
  Result := TElement(Call.Target);
end;

function MakeContext(Surface: TCanvasSurface; const Id: string; const Options: TBindingValue): TCanvasContextBase;
var
  Alpha, WillRead: Boolean;
  Renderer: TBitmapRendererContext;
begin
  Result := nil;
  Alpha := True;
  WillRead := False;
  if Length(Options.Items) > CanvasRenderingContext2DSettings_willReadFrequently then
  begin
    Alpha := Options.Items[CanvasRenderingContext2DSettings_alpha].Flag;
    WillRead := Options.Items[CanvasRenderingContext2DSettings_willReadFrequently].Flag;
  end;
  if Id = '2d' then
  begin
    if Surface.ContextKind = Context2D then
      Exit(Surface.Context);
    if Surface.ContextKind <> ContextNone then
      Exit(nil);
    Result := TCanvasContext2D.Create(Alpha, WillRead);
    Surface.SetContext(Context2D, Result);
    TCanvasContext2D(Result).Reset;
  end
  else if Id = 'bitmaprenderer' then
  begin
    if Surface.ContextKind = ContextBitmapRenderer then
      Exit(Surface.Context);
    if Surface.ContextKind <> ContextNone then
      Exit(nil);
    Renderer := TBitmapRendererContext.Create;
    Renderer.Alpha := Alpha;
    Surface.SetContext(ContextBitmapRenderer, Renderer);
    Result := Renderer;
  end;
end;

function HTMLCanvasElement_getContext(var Call: TBindingCall): TJsValue;
var
  Surface: TCanvasElementSurface;
begin
  Surface := CanvasSurfaceOf(CanvasElement(Call));
  if Surface.Offscreen <> nil then
    RaiseDomError(InvalidStateError, 'Cannot get a context from a canvas that has transferred its control to offscreen.');
  Result := WrapCanvasContext(Context(Call), MakeContext(Surface, Call.Text(0), Call.Arguments[1]));
end;

function QualityOf(const Call: TBindingCall; Index: Integer; out Quality: Double): Boolean;
var
  Value: TJsValue;
begin
  Value := Call.Script(Index);
  Result := JsIsNumber(Value);
  Quality := 0;
  if Result then
    Quality := ScriptNumber(Context(Call), Value);
end;

function HTMLCanvasElement_toDataURL(var Call: TBindingCall): TJsValue;
var
  Surface: TCanvasElementSurface;
  Quality: Double;
  HasQuality: Boolean;
begin
  Surface := CanvasSurfaceOf(CanvasElement(Call));
  if not Surface.OriginClean or ((Surface.Offscreen <> nil) and not Surface.Offscreen.OriginClean) then
    RaiseDomError('SecurityError', 'Tainted canvases may not be exported.');
  HasQuality := QualityOf(Call, 1, Quality);
  Result := Context(Call).TextValue(CanvasDataUrl(Surface.ShownBitmap, Call.Text(0), HasQuality, Quality));
end;

function HTMLCanvasElement_transferControlToOffscreen(var Call: TBindingCall): TJsValue;
var
  Surface: TCanvasElementSurface;
  Offscreen: TOffscreenCanvas;
begin
  Surface := CanvasSurfaceOf(CanvasElement(Call));
  if (Surface.ContextKind <> ContextNone) or (Surface.Offscreen <> nil) then
    RaiseDomError(InvalidStateError, 'Cannot transfer control from a canvas that has a rendering context or has been transferred.');
  Offscreen := TOffscreenCanvas.Create(Surface.Width, Surface.Height);
  Offscreen.Placeholder := Surface;
  Surface.Offscreen := Offscreen;
  Surface.Changed;
  Result := WrapOffscreen(Context(Call), Offscreen);
end;

{ ---- CanvasRenderingContext2D, OffscreenCanvasRenderingContext2D ---- }

function CanvasRenderingContext2D_get_canvas(var Call: TBindingCall): TJsValue;
begin
  Result := CanvasOfContext(Context(Call), Rendering(Call));
end;

function OffscreenCanvasRenderingContext2D_get_canvas(var Call: TBindingCall): TJsValue;
begin
  Result := CanvasOfContext(Context(Call), Rendering(Call));
end;

function CanvasRenderingContext2D_getContextAttributes(var Call: TBindingCall): TJsValue;
var
  R: TJsRealm;
  Attributes: TJsObject;
begin
  R := Context(Call).Engine.Realm;
  Attributes := R.NewPlainObject;
  Result := JsObjectValue(Attributes);
  Attributes.CreateDataProperty(R, R.Intern('alpha'), JsBoolean(Rendering(Call).Alpha));
  Attributes.CreateDataProperty(R, R.Intern('colorSpace'), Context(Call).TextValue('srgb'));
  Attributes.CreateDataProperty(R, R.Intern('desynchronized'), JsBoolean(False));
  Attributes.CreateDataProperty(R, R.Intern('willReadFrequently'), JsBoolean(Rendering(Call).WillReadFrequently));
end;

{ CanvasState }

function CanvasState_save(var Call: TBindingCall): TJsValue;
begin
  Rendering(Call).Save;
  Result := JsUndefined;
end;

function CanvasState_restore(var Call: TBindingCall): TJsValue;
begin
  Rendering(Call).Restore;
  Result := JsUndefined;
end;

function CanvasState_reset(var Call: TBindingCall): TJsValue;
begin
  Rendering(Call).Reset;
  Result := JsUndefined;
end;

function CanvasState_isContextLost(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(Rendering(Call).IsContextLost);
end;

{ CanvasTransform }

function CanvasTransform_scale(var Call: TBindingCall): TJsValue;
begin
  Rendering(Call).Scale(Call.Number(0), Call.Number(1));
  Result := JsUndefined;
end;

function CanvasTransform_rotate(var Call: TBindingCall): TJsValue;
begin
  Rendering(Call).Rotate(Call.Number(0));
  Result := JsUndefined;
end;

function CanvasTransform_translate(var Call: TBindingCall): TJsValue;
begin
  Rendering(Call).Translate(Call.Number(0), Call.Number(1));
  Result := JsUndefined;
end;

function CanvasTransform_transform(var Call: TBindingCall): TJsValue;
begin
  Rendering(Call).Transform(Call.Number(0), Call.Number(1), Call.Number(2), Call.Number(3), Call.Number(4),
    Call.Number(5));
  Result := JsUndefined;
end;

function NewMatrix(Ctx: TBindingContext; const T: TAffineTransform): TJsValue;
var
  Constructor_, Values: TJsValue;
  Mark: Integer;
begin
  Values := Ctx.NewArray([JsNumber(T.A), JsNumber(T.B), JsNumber(T.C), JsNumber(T.D), JsNumber(T.E),
    JsNumber(T.F)]);
  Constructor_ := GlobalConstructor(Ctx, 'DOMMatrix');
  if Constructor_ = JsUndefined then
    Exit(Values);
  Mark := Ctx.Engine.Runtime.PushRoot(Values);
  try
    Result := Ctx.Engine.Realm.Construct(Constructor_, @Values, 1, Constructor_);
    if Result = JsException then
      raise EBindingPendingException.Create('');
  finally
    Ctx.Engine.Runtime.PopRoots(Mark);
  end;
end;

function CanvasTransform_getTransform(var Call: TBindingCall): TJsValue;
begin
  Result := NewMatrix(Context(Call), Rendering(Call).State.Transform);
end;

function CanvasTransform_setTransform(var Call: TBindingCall): TJsValue;
var
  T: TAffineTransform;
begin
  Result := JsUndefined;
  if Call.Count = 6 then
  begin
    Rendering(Call).SetTransform(Call.Number(0), Call.Number(1), Call.Number(2), Call.Number(3), Call.Number(4),
      Call.Number(5));
    Exit;
  end;
  T := MatrixFromInit(Call.Arguments[0]);
  if TransformFinite(T) then
    Rendering(Call).SetTransform(T.A, T.B, T.C, T.D, T.E, T.F);
end;

function CanvasTransform_resetTransform(var Call: TBindingCall): TJsValue;
begin
  Rendering(Call).ResetTransform;
  Result := JsUndefined;
end;

{ CanvasCompositing }

function CanvasCompositing_get_globalAlpha(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(StateOf(Call)^.GlobalAlpha);
end;

function CanvasCompositing_set_globalAlpha(var Call: TBindingCall): TJsValue;
var
  Value: Double;
begin
  Value := Call.Number(0);
  if Finite(Value) and (Value >= 0) and (Value <= 1) then
    StateOf(Call)^.GlobalAlpha := Value;
  Result := JsUndefined;
end;

function CanvasCompositing_get_globalCompositeOperation(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(CompositeOperationNames[StateOf(Call)^.Operation]);
end;

function CanvasCompositing_set_globalCompositeOperation(var Call: TBindingCall): TJsValue;
var
  Operation: TCompositeOperation;
begin
  if CompositeOperationFromName(Call.Text(0), Operation) then
    StateOf(Call)^.Operation := Operation;
  Result := JsUndefined;
end;

{ CanvasImageSmoothing }

function CanvasImageSmoothing_get_imageSmoothingEnabled(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(StateOf(Call)^.ImageSmoothingEnabled);
end;

function CanvasImageSmoothing_set_imageSmoothingEnabled(var Call: TBindingCall): TJsValue;
begin
  StateOf(Call)^.ImageSmoothingEnabled := Call.Flag(0);
  Result := JsUndefined;
end;

function CanvasImageSmoothing_get_imageSmoothingQuality(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(SmoothingQualityNames[StateOf(Call)^.ImageSmoothingQuality]);
end;

function CanvasImageSmoothing_set_imageSmoothingQuality(var Call: TBindingCall): TJsValue;
begin
  StateOf(Call)^.ImageSmoothingQuality := TImageSmoothingQuality(Call.Int(0));
  Result := JsUndefined;
end;

{ CanvasFillStrokeStyles }

function StyleValue(const Call: TBindingCall; const Style: TCanvasPaintStyle): TJsValue;
begin
  case Style.Kind of
    StyleGradient: Result := WrapShared(Context(Call), Style.Gradient, InterfaceCanvasGradient, JsUndefined);
    StylePattern: Result := WrapShared(Context(Call), Style.Pattern, InterfaceCanvasPattern, JsUndefined);
  else
    Result := Context(Call).TextValue(SerializeCanvasColor(Style.Color));
  end;
end;

{ The style a script value gives; False when it is to be ignored. }
function StyleFromValue(const Call: TBindingCall; out Style: TCanvasPaintStyle): Boolean;
var
  Value: TJsValue;
  Native: TObject;
  Shared: TCanvasSharedObject;
  Color: TColor;
begin
  Result := False;
  Style := ColorStyle(ColorBlack);
  Value := Call.Script(0);
  if JsIsObject(Value) then
  begin
    Native := Context(Call).Unwrap(Value, InterfaceCanvasGradient);
    if Native = nil then
      Native := Context(Call).Unwrap(Value, InterfaceCanvasPattern);
    Shared := SharedOf(Native);
    if Shared is TCanvasGradient then
    begin
      Style.Kind := StyleGradient;
      Style.Gradient := TCanvasGradient(Shared);
      Exit(True);
    end;
    if Shared is TCanvasPattern then
    begin
      Style.Kind := StylePattern;
      Style.Pattern := TCanvasPattern(Shared);
      if not TCanvasPattern(Shared).OriginClean and (Rendering(Call).Surface <> nil) then
        Rendering(Call).Surface.OriginClean := False;
      Exit(True);
    end;
  end;
  if JsIsSymbol(Value) then
    Exit;
  if ParseCanvasColor(ValueToText(Context(Call).Engine.Realm, Value), SurfaceCurrentColor(Rendering(Call)), Color) then
  begin
    Style := ColorStyle(Color);
    Result := True;
  end;
end;

function CanvasFillStrokeStyles_get_fillStyle(var Call: TBindingCall): TJsValue;
begin
  Result := StyleValue(Call, StateOf(Call)^.FillStyle);
end;

function CanvasFillStrokeStyles_set_fillStyle(var Call: TBindingCall): TJsValue;
var
  Style: TCanvasPaintStyle;
begin
  if StyleFromValue(Call, Style) then
    Rendering(Call).SetFillStyle(Style);
  Result := JsUndefined;
end;

function CanvasFillStrokeStyles_get_strokeStyle(var Call: TBindingCall): TJsValue;
begin
  Result := StyleValue(Call, StateOf(Call)^.StrokeStyle);
end;

function CanvasFillStrokeStyles_set_strokeStyle(var Call: TBindingCall): TJsValue;
var
  Style: TCanvasPaintStyle;
begin
  if StyleFromValue(Call, Style) then
    Rendering(Call).SetStrokeStyle(Style);
  Result := JsUndefined;
end;

function NewGradient(const Call: TBindingCall; Kind: TCanvasGradientKind): TJsValue;
var
  Gradient: TCanvasGradient;
begin
  Gradient := TCanvasGradient.Create;
  Gradient.Kind := Kind;
  case Kind of
    GradientLinear:
      begin
        Gradient.X0 := Call.Number(0);
        Gradient.Y0 := Call.Number(1);
        Gradient.X1 := Call.Number(2);
        Gradient.Y1 := Call.Number(3);
      end;
    GradientRadial:
      begin
        Gradient.X0 := Call.Number(0);
        Gradient.Y0 := Call.Number(1);
        Gradient.R0 := Call.Number(2);
        Gradient.X1 := Call.Number(3);
        Gradient.Y1 := Call.Number(4);
        Gradient.R1 := Call.Number(5);
      end;
    GradientConic:
      begin
        Gradient.StartAngle := Call.Number(0);
        Gradient.X0 := Call.Number(1);
        Gradient.Y0 := Call.Number(2);
      end;
  end;
  try
    Result := WrapShared(Context(Call), Gradient, InterfaceCanvasGradient, JsUndefined);
  finally
    { The wrapper's handle holds it now. }
    Gradient.Release;
  end;
end;

function CanvasFillStrokeStyles_createLinearGradient(var Call: TBindingCall): TJsValue;
begin
  Result := NewGradient(Call, GradientLinear);
end;

function CanvasFillStrokeStyles_createRadialGradient(var Call: TBindingCall): TJsValue;
begin
  if (Call.Number(2) < 0) or (Call.Number(5) < 0) then
    RaiseDomError(IndexSizeError, 'The radius provided is negative.');
  Result := NewGradient(Call, GradientRadial);
end;

function CanvasFillStrokeStyles_createConicGradient(var Call: TBindingCall): TJsValue;
begin
  Result := NewGradient(Call, GradientConic);
end;

{ The source's pixels at its own (logical) size, copied. }
function SourceImageCopy(const Source: TCanvasImageSource): TImage;
var
  Width, Height: LongInt;
begin
  Width := Max(1, Round(Source.Width));
  Height := Max(1, Round(Source.Height));
  if (Width = Source.Image.Width) and (Height = Source.Image.Height) then
    Result := Source.Image.Clone
  else
    Result := ScaleImage(Source.Image, Width, Height);
end;

function CanvasFillStrokeStyles_createPattern(var Call: TBindingCall): TJsValue;
var
  Source: TCanvasImageSource;
  Repetition: TCanvasPatternRepetition;
  Pattern: TCanvasPattern;
begin
  if CanvasImageSourceOf(Call.Native(0), Source) <> SourceUsable then
    Exit(JsNull);
  if not ParsePatternRepetition(Call.Text(1), Repetition) then
    RaiseDomError(SyntaxError, 'The provided type (''' + Call.Text(1) + ''') is not one of ''repeat'', ' +
      '''no-repeat'', ''repeat-x'', or ''repeat-y''.');
  Pattern := TCanvasPattern.Create(SourceImageCopy(Source), Repetition);
  Pattern.OriginClean := Source.OriginClean;
  try
    Result := WrapShared(Context(Call), Pattern, InterfaceCanvasPattern, JsUndefined);
  finally
    Pattern.Release;
  end;
end;

{ CanvasShadowStyles }

function CanvasShadowStyles_get_shadowOffsetX(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(StateOf(Call)^.ShadowOffsetX);
end;

function CanvasShadowStyles_set_shadowOffsetX(var Call: TBindingCall): TJsValue;
begin
  if Finite(Call.Number(0)) then
    StateOf(Call)^.ShadowOffsetX := Call.Number(0);
  Result := JsUndefined;
end;

function CanvasShadowStyles_get_shadowOffsetY(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(StateOf(Call)^.ShadowOffsetY);
end;

function CanvasShadowStyles_set_shadowOffsetY(var Call: TBindingCall): TJsValue;
begin
  if Finite(Call.Number(0)) then
    StateOf(Call)^.ShadowOffsetY := Call.Number(0);
  Result := JsUndefined;
end;

function CanvasShadowStyles_get_shadowBlur(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(StateOf(Call)^.ShadowBlur);
end;

function CanvasShadowStyles_set_shadowBlur(var Call: TBindingCall): TJsValue;
begin
  if Finite(Call.Number(0)) and (Call.Number(0) >= 0) then
    StateOf(Call)^.ShadowBlur := Call.Number(0);
  Result := JsUndefined;
end;

function CanvasShadowStyles_get_shadowColor(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(SerializeCanvasColor(StateOf(Call)^.ShadowColor));
end;

function CanvasShadowStyles_set_shadowColor(var Call: TBindingCall): TJsValue;
var
  Color: TColor;
begin
  if ParseCanvasColor(Call.Text(0), SurfaceCurrentColor(Rendering(Call)), Color) then
    StateOf(Call)^.ShadowColor := Color;
  Result := JsUndefined;
end;

{ CanvasFilters }

function CanvasFilters_get_filter(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(StateOf(Call)^.FilterText);
end;

function CanvasFilters_set_filter(var Call: TBindingCall): TJsValue;
var
  Filter: TCanvasFilter;
begin
  if ParseCanvasFilter(Call.Text(0), SurfaceCurrentColor(Rendering(Call)), Filter) then
  begin
    StateOf(Call)^.Filter := Filter;
    StateOf(Call)^.FilterText := Call.Text(0);
  end;
  Result := JsUndefined;
end;

{ CanvasRect }

function CanvasRect_clearRect(var Call: TBindingCall): TJsValue;
begin
  Rendering(Call).ClearRect(Call.Number(0), Call.Number(1), Call.Number(2), Call.Number(3));
  Result := JsUndefined;
end;

function CanvasRect_fillRect(var Call: TBindingCall): TJsValue;
begin
  Rendering(Call).FillRect(Call.Number(0), Call.Number(1), Call.Number(2), Call.Number(3));
  Result := JsUndefined;
end;

function CanvasRect_strokeRect(var Call: TBindingCall): TJsValue;
begin
  Rendering(Call).StrokeRect(Call.Number(0), Call.Number(1), Call.Number(2), Call.Number(3));
  Result := JsUndefined;
end;

{ CanvasDrawPath }

function PathOfNative(Native: TObject): PCanvasPath;
begin
  if Native is TCanvasPath2D then
    Result := @TCanvasPath2D(Native).Path
  else
    Result := nil;
end;

function CanvasDrawPath_beginPath(var Call: TBindingCall): TJsValue;
begin
  Rendering(Call).BeginPath;
  Result := JsUndefined;
end;

{ (Path2D or CanvasFillRule) pathOrFillRule, CanvasFillRule fillRule. }
procedure PathAndRule(const Call: TBindingCall; out Path: PCanvasPath; out Rule: TFillRule);
begin
  Path := nil;
  Rule := FillRuleNonZero;
  if Call.Present(0) and (Call.Arguments[0].UnionMember = 0) then
  begin
    Path := PathOfNative(Call.Native(0));
    if Call.Present(1) then
      Rule := FillRuleOf(Call.Text(1));
  end
  else if Call.Present(0) then
    Rule := FillRuleOf(Call.Text(0));
end;

function CanvasDrawPath_fill(var Call: TBindingCall): TJsValue;
var
  Path: PCanvasPath;
  Rule: TFillRule;
begin
  PathAndRule(Call, Path, Rule);
  Rendering(Call).Fill(Path, Rule);
  Result := JsUndefined;
end;

function CanvasDrawPath_stroke(var Call: TBindingCall): TJsValue;
begin
  if Call.Present(0) then
    Rendering(Call).Stroke(PathOfNative(Call.Native(0)))
  else
    Rendering(Call).Stroke(nil);
  Result := JsUndefined;
end;

function CanvasDrawPath_clip(var Call: TBindingCall): TJsValue;
var
  Path: PCanvasPath;
  Rule: TFillRule;
begin
  PathAndRule(Call, Path, Rule);
  Rendering(Call).Clip(Path, Rule);
  Result := JsUndefined;
end;

function CanvasDrawPath_isPointInPath(var Call: TBindingCall): TJsValue;
var
  Path: PCanvasPath;
  X, Y: Double;
  Rule: TFillRule;
begin
  Rule := FillRuleNonZero;
  if Call.Arguments[0].UnionMember = 0 then
  begin
    Path := PathOfNative(Call.Native(0));
    if not Call.Present(2) or (Call.Arguments[2].UnionMember <> 0) then
      raise EBindingTypeError.Create('Failed to execute ''isPointInPath'': 3 arguments required with a path');
    X := Call.Number(1);
    Y := Call.Number(2);
    if Call.Present(3) then
      Rule := FillRuleOf(Call.Text(3));
  end
  else
  begin
    Path := nil;
    X := Call.Number(0);
    Y := Call.Number(1);
    if Call.Present(2) then
    begin
      if Call.Arguments[2].UnionMember = 0 then
        raise EBindingTypeError.Create('Failed to execute ''isPointInPath'': the fill rule is not valid');
      Rule := FillRuleOf(Call.Text(2));
    end;
  end;
  Result := JsBoolean(Rendering(Call).IsPointInPath(Path, X, Y, Rule));
end;

function CanvasDrawPath_isPointInStroke(var Call: TBindingCall): TJsValue;
begin
  if Call.Arguments[0].UnionMember = 0 then
  begin
    if not Call.Present(2) then
      raise EBindingTypeError.Create('Failed to execute ''isPointInStroke'': 3 arguments required with a path');
    Result := JsBoolean(Rendering(Call).IsPointInStroke(PathOfNative(Call.Native(0)), Call.Number(1),
      Call.Number(2)));
  end
  else
    Result := JsBoolean(Rendering(Call).IsPointInStroke(nil, Call.Number(0), Call.Number(1)));
end;

{ CanvasUserInterface }

function CanvasUserInterface_drawFocusIfNeeded(var Call: TBindingCall): TJsValue;
var
  Element, Canvas_: TElement;
  Path: PCanvasPath;
  State: TCanvasDrawingState;
  Surface: TCanvasSurface;
begin
  Result := JsUndefined;
  Path := nil;
  if Call.Present(0) and (Call.Arguments[0].UnionMember = 0) then
  begin
    Path := PathOfNative(Call.Native(0));
    if not Call.Present(1) then
      raise EBindingTypeError.Create('Failed to execute ''drawFocusIfNeeded'': an element is required');
    Element := TElement(Call.Native(1));
  end
  else
    Element := TElement(Call.Native(0));
  if Element = nil then
    raise EBindingTypeError.Create('Failed to execute ''drawFocusIfNeeded'': an element is required');
  Surface := Rendering(Call).Surface;
  if not (Surface is TCanvasElementSurface) then
    Exit;
  Canvas_ := TCanvasElementSurface(Surface).Element;
  { Only a focused fallback element of this canvas draws its ring. }
  if (Element.NodeDocument = nil) or (Element.NodeDocument.FocusedElement <> Element) or
     not Canvas_.IsInclusiveAncestorOf(Element) or (Element = Canvas_) then
    Exit;
  State := CopyDrawingState(Rendering(Call).State);
  try
    Rendering(Call).Save;
    try
      Rendering(Call).SetStrokeStyle(ColorStyle(RgbColor($1A, $73, $E8)));
      Rendering(Call).StateRef^.LineWidth := 2;
      Rendering(Call).StateRef^.LineDash := nil;
      Rendering(Call).StateRef^.ShadowColor := ColorTransparent;
      Rendering(Call).StateRef^.GlobalAlpha := 1;
      Rendering(Call).StateRef^.Operation := CompositeSourceOver;
      Rendering(Call).Stroke(Path);
    finally
      Rendering(Call).Restore;
    end;
  finally
    ReleaseDrawingState(State);
  end;
end;

{ CanvasText }

function MaxWidthOf(const Call: TBindingCall; out MaxWidth: Double): Boolean;
begin
  Result := Call.Present(3);
  MaxWidth := Call.Number(3);
end;

function CanvasText_fillText(var Call: TBindingCall): TJsValue;
var
  MaxWidth: Double;
  HasMaxWidth: Boolean;
begin
  HasMaxWidth := MaxWidthOf(Call, MaxWidth);
  Rendering(Call).FillText(Call.Text(0), Call.Number(1), Call.Number(2), HasMaxWidth, MaxWidth);
  Result := JsUndefined;
end;

function CanvasText_strokeText(var Call: TBindingCall): TJsValue;
var
  MaxWidth: Double;
  HasMaxWidth: Boolean;
begin
  HasMaxWidth := MaxWidthOf(Call, MaxWidth);
  Rendering(Call).StrokeText(Call.Text(0), Call.Number(1), Call.Number(2), HasMaxWidth, MaxWidth);
  Result := JsUndefined;
end;

function CanvasText_measureText(var Call: TBindingCall): TJsValue;
var
  Metrics: TCanvasTextMetrics;
begin
  Metrics := TCanvasTextMetrics.Create;
  Metrics.Measure := Rendering(Call).MeasureText(Call.Text(0));
  Result := Context(Call).WrapObject(Metrics, InterfaceTextMetrics, True, JsUndefined);
end;

{ CanvasDrawImage }

function CanvasDrawImage_drawImage(var Call: TBindingCall): TJsValue;
var
  Source: TCanvasImageSource;
begin
  Result := JsUndefined;
  if CanvasImageSourceOf(Call.Native(0), Source) <> SourceUsable then
    Exit;
  case Call.Count of
    3:
      Rendering(Call).DrawImage(Source, 0, 0, Source.Width, Source.Height, Call.Number(1), Call.Number(2),
        Source.Width, Source.Height);
    5:
      Rendering(Call).DrawImage(Source, 0, 0, Source.Width, Source.Height, Call.Number(1), Call.Number(2),
        Call.Number(3), Call.Number(4));
  else
    Rendering(Call).DrawImage(Source, Call.Number(1), Call.Number(2), Call.Number(3), Call.Number(4),
      Call.Number(5), Call.Number(6), Call.Number(7), Call.Number(8));
  end;
end;

{ CanvasImageData }

function ImageDataOf(Native: TObject): TCanvasImageData;
begin
  if not (Native is TCanvasImageData) then
    raise EBindingTypeError.Create('The provided value is not of type ''ImageData''');
  Result := TCanvasImageData(Native);
end;

function CanvasImageData_createImageData(var Call: TBindingCall): TJsValue;
var
  Data: TCanvasImageData;
  Width, Height: Int64;
begin
  if Call.Count = 1 then
  begin
    Data := ImageDataOf(Call.Native(0));
    Exit(NewImageData(Context(Call), Data.Width, Data.Height, 'srgb', Data));
  end;
  Width := Call.Int(0);
  Height := Call.Int(1);
  if (Width = 0) or (Height = 0) then
    RaiseDomError(IndexSizeError, 'The source width or height is 0.');
  Result := NewImageData(Context(Call), Abs(Width), Abs(Height), 'srgb', Data);
end;

function CanvasImageData_getImageData(var Call: TBindingCall): TJsValue;
var
  X, Y, Width, Height: Int64;
  Data: TCanvasImageData;
  Pixels: PByte;
begin
  X := Call.Int(0);
  Y := Call.Int(1);
  Width := Call.Int(2);
  Height := Call.Int(3);
  if (Width = 0) or (Height = 0) then
    RaiseDomError(IndexSizeError, 'The source width or height is 0.');
  if (Rendering(Call).Surface <> nil) and not Rendering(Call).Surface.OriginClean then
    RaiseDomError('SecurityError', 'The canvas has been tainted by cross-origin data.');
  if Width < 0 then
  begin
    X := X + Width;
    Width := -Width;
  end;
  if Height < 0 then
  begin
    Y := Y + Height;
    Height := -Height;
  end;
  Result := NewImageData(Context(Call), Width, Height, 'srgb', Data);
  if Data.Bytes(Pixels) then
    Rendering(Call).GetImageBytes(X, Y, Width, Height, Pixels);
end;

function CanvasImageData_putImageData(var Call: TBindingCall): TJsValue;
var
  Data: TCanvasImageData;
  Pixels: PByte;
begin
  Data := ImageDataOf(Call.Native(0));
  if not Data.Bytes(Pixels) then
    RaiseDomError(InvalidStateError, 'The source data has been detached.');
  if Call.Count = 3 then
    Rendering(Call).PutImageBytes(Pixels, Data.Width, Data.Height, Call.Int(1), Call.Int(2), 0, 0, Data.Width,
      Data.Height)
  else
    Rendering(Call).PutImageBytes(Pixels, Data.Width, Data.Height, Call.Int(1), Call.Int(2), Call.Int(3),
      Call.Int(4), Call.Int(5), Call.Int(6));
  Result := JsUndefined;
end;

{ CanvasPathDrawingStyles }

function CanvasPathDrawingStyles_get_lineWidth(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(StateOf(Call)^.LineWidth);
end;

function CanvasPathDrawingStyles_set_lineWidth(var Call: TBindingCall): TJsValue;
begin
  if Finite(Call.Number(0)) and (Call.Number(0) > 0) then
    StateOf(Call)^.LineWidth := Call.Number(0);
  Result := JsUndefined;
end;

function CanvasPathDrawingStyles_get_lineCap(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(LineCapNames[StateOf(Call)^.LineCap]);
end;

function CanvasPathDrawingStyles_set_lineCap(var Call: TBindingCall): TJsValue;
begin
  case Call.Text(0) of
    'butt': StateOf(Call)^.LineCap := LineCapButt;
    'round': StateOf(Call)^.LineCap := LineCapRound;
    'square': StateOf(Call)^.LineCap := LineCapSquare;
  end;
  Result := JsUndefined;
end;

function CanvasPathDrawingStyles_get_lineJoin(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(LineJoinNames[StateOf(Call)^.LineJoin]);
end;

function CanvasPathDrawingStyles_set_lineJoin(var Call: TBindingCall): TJsValue;
begin
  case Call.Text(0) of
    'miter': StateOf(Call)^.LineJoin := LineJoinMiter;
    'round': StateOf(Call)^.LineJoin := LineJoinRound;
    'bevel': StateOf(Call)^.LineJoin := LineJoinBevel;
  end;
  Result := JsUndefined;
end;

function CanvasPathDrawingStyles_get_miterLimit(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(StateOf(Call)^.MiterLimit);
end;

function CanvasPathDrawingStyles_set_miterLimit(var Call: TBindingCall): TJsValue;
begin
  if Finite(Call.Number(0)) and (Call.Number(0) > 0) then
    StateOf(Call)^.MiterLimit := Call.Number(0);
  Result := JsUndefined;
end;

function CanvasPathDrawingStyles_setLineDash(var Call: TBindingCall): TJsValue;
var
  Segments: array of Double;
  Index: Integer;
begin
  Segments := nil;
  SetLength(Segments, Length(Call.Arguments[0].Items));
  for Index := 0 to High(Segments) do
    Segments[Index] := Call.Arguments[0].Items[Index].Number;
  Rendering(Call).SetLineDash(Segments);
  Result := JsUndefined;
end;

function CanvasPathDrawingStyles_getLineDash(var Call: TBindingCall): TJsValue;
var
  Values: array of TJsValue;
  Index: Integer;
begin
  Values := nil;
  SetLength(Values, Length(StateOf(Call)^.LineDash));
  for Index := 0 to High(Values) do
    Values[Index] := JsNumber(StateOf(Call)^.LineDash[Index]);
  Result := Context(Call).NewArray(Values);
end;

function CanvasPathDrawingStyles_get_lineDashOffset(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(StateOf(Call)^.LineDashOffset);
end;

function CanvasPathDrawingStyles_set_lineDashOffset(var Call: TBindingCall): TJsValue;
begin
  if Finite(Call.Number(0)) then
    StateOf(Call)^.LineDashOffset := Call.Number(0);
  Result := JsUndefined;
end;

{ CanvasTextDrawingStyles }

function CanvasTextDrawingStyles_get_font(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(StateOf(Call)^.Text.Font.Text);
end;

function CanvasTextDrawingStyles_set_font(var Call: TBindingCall): TJsValue;
begin
  ParseCanvasFont(Call.Text(0), StateOf(Call)^.Text.Font);
  Result := JsUndefined;
end;

function CanvasTextDrawingStyles_get_textAlign(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(TextAlignNames[StateOf(Call)^.Text.Align]);
end;

function CanvasTextDrawingStyles_set_textAlign(var Call: TBindingCall): TJsValue;
begin
  StateOf(Call)^.Text.Align := TCanvasTextAlign(Call.Int(0));
  Result := JsUndefined;
end;

function CanvasTextDrawingStyles_get_textBaseline(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(TextBaselineNames[StateOf(Call)^.Text.Baseline]);
end;

function CanvasTextDrawingStyles_set_textBaseline(var Call: TBindingCall): TJsValue;
begin
  StateOf(Call)^.Text.Baseline := TCanvasTextBaseline(Call.Int(0));
  Result := JsUndefined;
end;

function CanvasTextDrawingStyles_get_direction(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(DirectionNames[StateOf(Call)^.Text.Direction]);
end;

function CanvasTextDrawingStyles_set_direction(var Call: TBindingCall): TJsValue;
begin
  StateOf(Call)^.Text.Direction := TCanvasDirection(Call.Int(0));
  Result := JsUndefined;
end;

function CanvasTextDrawingStyles_get_letterSpacing(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(StateOf(Call)^.LetterSpacingText);
end;

function CanvasTextDrawingStyles_set_letterSpacing(var Call: TBindingCall): TJsValue;
var
  Pixels: Double;
begin
  if ParseSpacing(Call.Text(0), StateOf(Call)^.Text.Font.Size, Pixels) then
  begin
    StateOf(Call)^.Text.LetterSpacing := Pixels;
    StateOf(Call)^.LetterSpacingText := Trim(LowerCase(Call.Text(0)));
  end;
  Result := JsUndefined;
end;

function CanvasTextDrawingStyles_get_wordSpacing(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(StateOf(Call)^.WordSpacingText);
end;

function CanvasTextDrawingStyles_set_wordSpacing(var Call: TBindingCall): TJsValue;
var
  Pixels: Double;
begin
  if ParseSpacing(Call.Text(0), StateOf(Call)^.Text.Font.Size, Pixels) then
  begin
    StateOf(Call)^.Text.WordSpacing := Pixels;
    StateOf(Call)^.WordSpacingText := Trim(LowerCase(Call.Text(0)));
  end;
  Result := JsUndefined;
end;

function CanvasTextDrawingStyles_get_fontKerning(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(StateOf(Call)^.FontKerning);
end;

function CanvasTextDrawingStyles_set_fontKerning(var Call: TBindingCall): TJsValue;
begin
  StateOf(Call)^.FontKerning := Call.Text(0);
  Result := JsUndefined;
end;

function CanvasTextDrawingStyles_get_fontStretch(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(StateOf(Call)^.FontStretch);
end;

function CanvasTextDrawingStyles_set_fontStretch(var Call: TBindingCall): TJsValue;
begin
  StateOf(Call)^.FontStretch := Call.Text(0);
  Result := JsUndefined;
end;

function CanvasTextDrawingStyles_get_fontVariantCaps(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(StateOf(Call)^.FontVariantCaps);
end;

function CanvasTextDrawingStyles_set_fontVariantCaps(var Call: TBindingCall): TJsValue;
begin
  StateOf(Call)^.FontVariantCaps := Call.Text(0);
  Result := JsUndefined;
end;

function CanvasTextDrawingStyles_get_textRendering(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(StateOf(Call)^.TextRendering);
end;

function CanvasTextDrawingStyles_set_textRendering(var Call: TBindingCall): TJsValue;
begin
  StateOf(Call)^.TextRendering := Call.Text(0);
  Result := JsUndefined;
end;

{ CanvasPath: a context's current default path (through its
  transform) or a Path2D's (as given). }

procedure PathTarget(const Call: TBindingCall; out Path: PCanvasPath; out Transform: TAffineTransform);
begin
  if Call.Target is TCanvasPath2D then
  begin
    Path := @TCanvasPath2D(Call.Target).Path;
    Transform := IdentityTransform;
  end
  else
  begin
    Path := Rendering(Call).CurrentPath;
    Transform := Rendering(Call).State.Transform;
  end;
end;

function CanvasPath_closePath(var Call: TBindingCall): TJsValue;
var
  Path: PCanvasPath;
  Transform: TAffineTransform;
begin
  PathTarget(Call, Path, Transform);
  CanvasClosePath(Path^);
  Result := JsUndefined;
end;

function CanvasPath_moveTo(var Call: TBindingCall): TJsValue;
var
  Path: PCanvasPath;
  Transform: TAffineTransform;
begin
  PathTarget(Call, Path, Transform);
  CanvasMoveTo(Path^, Transform, Call.Number(0), Call.Number(1));
  Result := JsUndefined;
end;

function CanvasPath_lineTo(var Call: TBindingCall): TJsValue;
var
  Path: PCanvasPath;
  Transform: TAffineTransform;
begin
  PathTarget(Call, Path, Transform);
  CanvasLineTo(Path^, Transform, Call.Number(0), Call.Number(1));
  Result := JsUndefined;
end;

function CanvasPath_quadraticCurveTo(var Call: TBindingCall): TJsValue;
var
  Path: PCanvasPath;
  Transform: TAffineTransform;
begin
  PathTarget(Call, Path, Transform);
  CanvasQuadraticCurveTo(Path^, Transform, Call.Number(0), Call.Number(1), Call.Number(2), Call.Number(3));
  Result := JsUndefined;
end;

function CanvasPath_bezierCurveTo(var Call: TBindingCall): TJsValue;
var
  Path: PCanvasPath;
  Transform: TAffineTransform;
begin
  PathTarget(Call, Path, Transform);
  CanvasBezierCurveTo(Path^, Transform, Call.Number(0), Call.Number(1), Call.Number(2), Call.Number(3),
    Call.Number(4), Call.Number(5));
  Result := JsUndefined;
end;

procedure RaisePathError(Error: Exception);
begin
  if Error is ECanvasIndexSizeError then
    RaiseDomError(IndexSizeError, Error.Message);
  if Error is ECanvasRangeError then
    raise EBindingRangeError.Create(Error.Message);
end;

function CanvasPath_arcTo(var Call: TBindingCall): TJsValue;
var
  Path: PCanvasPath;
  Transform: TAffineTransform;
begin
  PathTarget(Call, Path, Transform);
  try
    CanvasArcTo(Path^, Transform, Call.Number(0), Call.Number(1), Call.Number(2), Call.Number(3), Call.Number(4));
  except
    on Error: ECanvasIndexSizeError do
      RaisePathError(Error);
  end;
  Result := JsUndefined;
end;

function CanvasPath_rect(var Call: TBindingCall): TJsValue;
var
  Path: PCanvasPath;
  Transform: TAffineTransform;
begin
  PathTarget(Call, Path, Transform);
  CanvasRect(Path^, Transform, Call.Number(0), Call.Number(1), Call.Number(2), Call.Number(3));
  Result := JsUndefined;
end;

{ One radius: a number, or a DOMPointInit's x and y. }
function RadiusFromValue(Ctx: TBindingContext; Value: TJsValue): TCornerRadius;
var
  Part: TJsValue;
begin
  if JsIsObject(Value) then
  begin
    Part := PropertyOf(Ctx, Value, 'x');
    if Part = JsUndefined then
      Result.X := 0
    else
      Result.X := ScriptNumber(Ctx, Part);
    Part := PropertyOf(Ctx, Value, 'y');
    if Part = JsUndefined then
      Result.Y := 0
    else
      Result.Y := ScriptNumber(Ctx, Part);
  end
  else
  begin
    Result.X := ScriptNumber(Ctx, Value);
    Result.Y := Result.X;
  end;
end;

function CanvasPath_roundRect(var Call: TBindingCall): TJsValue;
var
  Path: PCanvasPath;
  Transform: TAffineTransform;
  Radii: TCornerRadii;
  Value, CountValue: TJsValue;
  Count, Index: Integer;
  Ctx: TBindingContext;
begin
  Ctx := Context(Call);
  PathTarget(Call, Path, Transform);
  Radii := nil;
  Value := Call.Script(4);
  if not Call.Present(4) or (Value = JsUndefined) then
  begin
    SetLength(Radii, 1);
    Radii[0].X := 0;
    Radii[0].Y := 0;
  end
  else if JsIsObject(Value) and (JsAsObject(Value) is TJsArray) then
  begin
    CountValue := PropertyOf(Ctx, Value, 'length');
    Count := Trunc(ScriptNumber(Ctx, CountValue));
    if (Count < 1) or (Count > 4) then
      raise EBindingRangeError.Create(IntToStr(Count) + ' radii provided. Between one and four radii are necessary.');
    SetLength(Radii, Count);
    for Index := 0 to Count - 1 do
      Radii[Index] := RadiusFromValue(Ctx, GetProperty(Ctx.Engine.Realm, Value, JsNumber(Index)));
  end
  else
  begin
    SetLength(Radii, 1);
    Radii[0] := RadiusFromValue(Ctx, Value);
  end;
  try
    CanvasRoundRect(Path^, Transform, Call.Number(0), Call.Number(1), Call.Number(2), Call.Number(3), Radii);
  except
    on Error: ECanvasRangeError do
      RaisePathError(Error);
  end;
  Result := JsUndefined;
end;

function CanvasPath_arc(var Call: TBindingCall): TJsValue;
var
  Path: PCanvasPath;
  Transform: TAffineTransform;
begin
  PathTarget(Call, Path, Transform);
  try
    CanvasArc(Path^, Transform, Call.Number(0), Call.Number(1), Call.Number(2), Call.Number(3), Call.Number(4),
      Call.Flag(5));
  except
    on Error: ECanvasIndexSizeError do
      RaisePathError(Error);
  end;
  Result := JsUndefined;
end;

function CanvasPath_ellipse(var Call: TBindingCall): TJsValue;
var
  Path: PCanvasPath;
  Transform: TAffineTransform;
begin
  PathTarget(Call, Path, Transform);
  try
    CanvasEllipse(Path^, Transform, Call.Number(0), Call.Number(1), Call.Number(2), Call.Number(3), Call.Number(4),
      Call.Number(5), Call.Number(6), Call.Flag(7));
  except
    on Error: ECanvasIndexSizeError do
      RaisePathError(Error);
  end;
  Result := JsUndefined;
end;

{ ---- CanvasGradient, CanvasPattern ---- }

function CanvasGradient_addColorStop(var Call: TBindingCall): TJsValue;
var
  Gradient: TCanvasGradient;
  Color: TColor;
begin
  Gradient := TCanvasGradient(SharedOf(Call.Target));
  if (Call.Number(0) < 0) or (Call.Number(0) > 1) then
    RaiseDomError(IndexSizeError, 'The provided value (' + FloatToStr(Call.Number(0)) +
      ') is outside the range (0.0, 1.0).');
  if not ParseCanvasColor(Call.Text(1), ColorBlack, Color) then
    RaiseDomError(SyntaxError, 'The value provided (''' + Call.Text(1) + ''') could not be parsed as a color.');
  Gradient.AddStop(Call.Number(0), Color);
  Result := JsUndefined;
end;

function CanvasPattern_setTransform(var Call: TBindingCall): TJsValue;
var
  T: TAffineTransform;
begin
  T := MatrixFromInit(Call.Arguments[0]);
  if TransformFinite(T) then
    TCanvasPattern(SharedOf(Call.Target)).Transform := T;
  Result := JsUndefined;
end;

{ ---- TextMetrics ---- }

function Metrics(const Call: TBindingCall): TCanvasTextMeasure; inline;
begin
  Result := TCanvasTextMetrics(Call.Target).Measure;
end;

function TextMetrics_get_width(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(Metrics(Call).Width);
end;

function TextMetrics_get_actualBoundingBoxLeft(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(Metrics(Call).ActualLeft);
end;

function TextMetrics_get_actualBoundingBoxRight(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(Metrics(Call).ActualRight);
end;

function TextMetrics_get_fontBoundingBoxAscent(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(Metrics(Call).FontAscent);
end;

function TextMetrics_get_fontBoundingBoxDescent(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(Metrics(Call).FontDescent);
end;

function TextMetrics_get_actualBoundingBoxAscent(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(Metrics(Call).ActualAscent);
end;

function TextMetrics_get_actualBoundingBoxDescent(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(Metrics(Call).ActualDescent);
end;

function TextMetrics_get_emHeightAscent(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(Metrics(Call).EmAscent);
end;

function TextMetrics_get_emHeightDescent(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(Metrics(Call).EmDescent);
end;

function TextMetrics_get_hangingBaseline(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(Metrics(Call).HangingBaseline);
end;

function TextMetrics_get_alphabeticBaseline(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(Metrics(Call).AlphabeticBaseline);
end;

function TextMetrics_get_ideographicBaseline(var Call: TBindingCall): TJsValue;
begin
  Result := NumberValue(Metrics(Call).IdeographicBaseline);
end;

{ ---- ImageData ---- }

{ An [EnforceRange] unsigned long from a script value. }
function EnforcedUnsigned(Ctx: TBindingContext; Value: TJsValue): Int64;
var
  Number: Double;
begin
  Number := ScriptNumber(Ctx, Value);
  if not Finite(Number) then
    raise EBindingTypeError.Create('Value is not a finite number');
  Number := Trunc(Number);
  if (Number < 0) or (Number > 4294967295.0) then
    raise EBindingTypeError.Create('Value is outside the ''unsigned long'' value range');
  Result := Trunc(Number);
end;

function ImageData_constructor(var Call: TBindingCall): TJsValue;
var
  Ctx: TBindingContext;
  First: TJsValue;
  Width, Height, Pixels: Int64;
  Data: TCanvasImageData;
  ArrayObject: TJsObject;
  Typed: TJsTypedArray;
  Length_: Int64;
begin
  Ctx := Context(Call);
  First := Call.Script(0);
  if JsIsObject(First) then
  begin
    ArrayObject := JsAsObject(First);
    if not (ArrayObject is TJsTypedArray) or (TJsTypedArray(ArrayObject).ElementKind <> taUint8Clamped) then
      raise EBindingTypeError.Create('Failed to construct ''ImageData'': parameter 1 is not of type ' +
        '''Uint8ClampedArray''.');
    Typed := TJsTypedArray(ArrayObject);
    Length_ := Typed.CurrentLength;
    if (Length_ = 0) or (Length_ mod 4 <> 0) then
      RaiseDomError(InvalidStateError, 'The input data length is not a multiple of 4.');
    Width := Call.Int(1);
    if Width = 0 then
      RaiseDomError(IndexSizeError, 'The source width is zero or not a number.');
    Pixels := Length_ div 4;
    if Pixels mod Width <> 0 then
      RaiseDomError(IndexSizeError, 'The input data length is not a multiple of (4 * width).');
    Height := Pixels div Width;
    if Call.Present(2) and (Call.Script(2) <> JsUndefined) then
      if EnforcedUnsigned(Ctx, Call.Script(2)) <> Height then
        RaiseDomError(IndexSizeError, 'The input data length is not equal to (4 * width * height).');
    Data := TCanvasImageData.Create;
    Data.Width := Width;
    Data.Height := Height;
    Data.Data := First;
    Data.ColorSpace := 'srgb';
    Exit(Ctx.ConstructedObject(Call, Data));
  end;
  Width := EnforcedUnsigned(Ctx, First);
  Height := Call.Int(1);
  if (Width = 0) or (Height = 0) then
    RaiseDomError(IndexSizeError, 'The source width or height is zero.');
  if Width * Height * 4 > MaximumArrayBufferLength then
    raise EBindingRangeError.Create('The ImageData is too large');
  Result := NewImageData(Ctx, Width, Height, 'srgb', Data);
  Ctx.AdjustConstructedPrototype(Result, Call);
end;

function ImageDataThis(const Call: TBindingCall): TCanvasImageData; inline;
begin
  Result := TCanvasImageData(Call.Target);
end;

function ImageData_get_width(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(ImageDataThis(Call).Width);
end;

function ImageData_get_height(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(ImageDataThis(Call).Height);
end;

function ImageData_get_data(var Call: TBindingCall): TJsValue;
begin
  Result := ImageDataThis(Call).Data;
end;

function ImageData_get_colorSpace(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ImageDataThis(Call).ColorSpace);
end;

{ ---- Path2D ---- }

function Path2D_constructor(var Call: TBindingCall): TJsValue;
var
  Path: TCanvasPath2D;
  Source: TObject;
begin
  Path := TCanvasPath2D.Create;
  try
    if Call.Present(0) then
    begin
      if Call.Arguments[0].UnionMember = 0 then
      begin
        Source := Call.Native(0);
        if Source is TCanvasPath2D then
        begin
          CanvasAddPath(Path.Path, TCanvasPath2D(Source).Path, IdentityTransform);
          Path.Path.Path.CurrentPoint := TCanvasPath2D(Source).Path.Path.CurrentPoint;
          Path.Path.Path.StartPoint := TCanvasPath2D(Source).Path.Path.StartPoint;
          Path.Path.Path.HasCurrentPoint := TCanvasPath2D(Source).Path.Path.HasCurrentPoint;
          Path.Path.Empty := TCanvasPath2D(Source).Path.Empty;
        end;
      end
      else
      begin
        ParsePathData(Call.Text(0), Path.Path.Path);
        Path.Path.Empty := Path.Path.Path.Count = 0;
      end;
    end;
  except
    Path.Free;
    raise;
  end;
  Result := Context(Call).ConstructedObject(Call, Path);
end;

function Path2D_addPath(var Call: TBindingCall): TJsValue;
var
  Source: TObject;
  T: TAffineTransform;
begin
  Result := JsUndefined;
  Source := Call.Native(0);
  if not (Source is TCanvasPath2D) then
    raise EBindingTypeError.Create('Failed to execute ''addPath'': parameter 1 is not of type ''Path2D''.');
  T := MatrixFromInit(Call.Arguments[1]);
  if not TransformFinite(T) then
    Exit;
  CanvasAddPath(TCanvasPath2D(Call.Target).Path, TCanvasPath2D(Source).Path, T);
end;

{ ---- ImageBitmap ---- }

function BitmapThis(const Call: TBindingCall): TCanvasImageBitmap; inline;
begin
  Result := TCanvasImageBitmap(SharedOf(Call.Target));
end;

function ImageBitmap_get_width(var Call: TBindingCall): TJsValue;
begin
  if BitmapThis(Call).Image = nil then
    Exit(JsInteger(0));
  Result := JsNumber(BitmapThis(Call).Image.Width);
end;

function ImageBitmap_get_height(var Call: TBindingCall): TJsValue;
begin
  if BitmapThis(Call).Image = nil then
    Exit(JsInteger(0));
  Result := JsNumber(BitmapThis(Call).Image.Height);
end;

function ImageBitmap_close(var Call: TBindingCall): TJsValue;
begin
  BitmapThis(Call).Close;
  Result := JsUndefined;
end;

{ ---- ImageBitmapRenderingContext ---- }

function RendererThis(const Call: TBindingCall): TBitmapRendererContext;
var
  Shared: TCanvasSharedObject;
begin
  Shared := SharedOf(Call.Target);
  if not (Shared is TBitmapRendererContext) then
    raise EBindingTypeError.Create('Illegal invocation');
  Result := TBitmapRendererContext(Shared);
end;

function ImageBitmapRenderingContext_get_canvas(var Call: TBindingCall): TJsValue;
begin
  Result := CanvasOfContext(Context(Call), RendererThis(Call));
end;

function ImageBitmapRenderingContext_transferFromImageBitmap(var Call: TBindingCall): TJsValue;
var
  Bitmap: TCanvasImageBitmap;
begin
  Bitmap := nil;
  if not Call.IsNull(0) then
  begin
    Bitmap := TCanvasImageBitmap(SharedOf(Call.Native(0)));
    if (Bitmap = nil) or (Bitmap.Image = nil) then
      RaiseDomError(InvalidStateError, 'The input ImageBitmap has been detached');
  end;
  RendererThis(Call).TransferFrom(Bitmap);
  Result := JsUndefined;
end;

{ ---- OffscreenCanvas ---- }

function OffscreenThis(const Call: TBindingCall): TOffscreenCanvas;
begin
  Result := TOffscreenCanvasHandle(Call.Target).Canvas;
end;

function OffscreenCanvas_constructor(var Call: TBindingCall): TJsValue;
var
  Canvas: TOffscreenCanvas;
begin
  Canvas := TOffscreenCanvas.Create(Min(Call.Int(0), High(LongInt)), Min(Call.Int(1), High(LongInt)));
  try
    Result := Context(Call).ConstructedObject(Call, TOffscreenCanvasHandle.Create(Canvas));
    Canvas.ScriptWrapper := TBindingWrapper(JsAsObject(Result));
  finally
    Canvas.Release;
  end;
end;

function OffscreenCanvas_get_width(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(OffscreenThis(Call).Width);
end;

function OffscreenCanvas_get_height(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(OffscreenThis(Call).Height);
end;

procedure CheckAttached(Canvas: TOffscreenCanvas);
begin
  if Canvas.Detached then
    RaiseDomError(InvalidStateError, 'The OffscreenCanvas is detached.');
end;

function OffscreenCanvas_set_width(var Call: TBindingCall): TJsValue;
begin
  CheckAttached(OffscreenThis(Call));
  OffscreenThis(Call).Resize(Min(Call.Int(0), High(LongInt)), OffscreenThis(Call).Height);
  Result := JsUndefined;
end;

function OffscreenCanvas_set_height(var Call: TBindingCall): TJsValue;
begin
  CheckAttached(OffscreenThis(Call));
  OffscreenThis(Call).Resize(OffscreenThis(Call).Width, Min(Call.Int(0), High(LongInt)));
  Result := JsUndefined;
end;

function OffscreenCanvas_getContext(var Call: TBindingCall): TJsValue;
begin
  CheckAttached(OffscreenThis(Call));
  Result := WrapCanvasContext(Context(Call), MakeContext(OffscreenThis(Call), Call.Text(0), Call.Arguments[1]));
end;

function OffscreenCanvas_transferToImageBitmap(var Call: TBindingCall): TJsValue;
var
  Canvas: TOffscreenCanvas;
  Image: TImage;
  Bitmap: TCanvasImageBitmap;
begin
  Canvas := OffscreenThis(Call);
  CheckAttached(Canvas);
  if Canvas.ContextKind = ContextNone then
    RaiseDomError(InvalidStateError, 'Cannot transfer an ImageBitmap from an OffscreenCanvas with no context');
  if Canvas.Bitmap = nil then
    RaiseDomError(InvalidStateError, 'Cannot transfer an ImageBitmap from an OffscreenCanvas of no pixels');
  Image := Canvas.Bitmap.Clone;
  if (Canvas.Context is TCanvasContext2D) and not TCanvasContext2D(Canvas.Context).Alpha then
    Canvas.Bitmap.Fill(ColorBlack)
  else
    Canvas.Bitmap.Fill(ColorTransparent);
  Canvas.Changed;
  Bitmap := TCanvasImageBitmap.Create(Image, Canvas.OriginClean);
  try
    Result := WrapShared(Context(Call), Bitmap, InterfaceImageBitmap, JsUndefined);
  finally
    Bitmap.Release;
  end;
end;

end.

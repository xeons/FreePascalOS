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
  The keywords the style engine knows by name.

  Each keyword's spelling comes from its identifier: kwInlineBlock is
  "inline-block" (a capital starts a new hyphenated word, digits stay
  with the word before), and a leading Webkit is the "-webkit-" vendor
  prefix. The atom table (Css.Atoms) is seeded in this order, so a
  keyword's atom is its ordinal: KeywordOfAtom is a range check.

  New keywords go anywhere in the list; their atoms are fixed when the
  library starts, never stored.
}
unit Css.Keywords;

{$mode objfpc}
{$H+}

interface

type
  TCssKeyword = (
    kwInvalid,
    { CSS-wide and general }
    kwInitial, kwInherit, kwUnset, kwRevert, kwRevertLayer, kwDefault,
    kwAuto, kwNone, kwNormal, kwAll, kwOnly, kwNot, kwAnd, kwOr, kwFrom, kwTo, kwAt, kwIn,
    kwLayer, kwSelector, kwSupports,
    { display }
    kwBlock, kwInline, kwRunIn, kwFlow, kwFlowRoot, kwTable, kwFlex, kwGrid, kwRuby,
    kwListItem, kwTableRowGroup, kwTableHeaderGroup, kwTableFooterGroup, kwTableRow,
    kwTableCell, kwTableColumnGroup, kwTableColumn, kwTableCaption, kwRubyBase, kwRubyText,
    kwRubyBaseContainer, kwRubyTextContainer, kwContents, kwInlineBlock, kwInlineTable,
    kwInlineFlex, kwInlineGrid, kwInlineListItem, kwMath, kwWebkitBox, kwWebkitInlineBox,
    { position, float, alignment, flex and grid }
    kwStatic, kwRelative, kwAbsolute, kwFixed, kwSticky,
    kwLeft, kwRight, kwTop, kwBottom, kwCenter, kwInlineStart, kwInlineEnd, kwBlockStart,
    kwBlockEnd, kwBoth, kwStart, kwEnd, kwSelfStart, kwSelfEnd, kwFlexStart, kwFlexEnd,
    kwBaseline, kwFirst, kwLast, kwStretch, kwSpaceBetween, kwSpaceAround, kwSpaceEvenly,
    kwSafe, kwUnsafe, kwLegacy, kwRow, kwRowReverse, kwColumn, kwColumnReverse, kwWrap,
    kwNowrap, kwWrapReverse, kwDense, kwContent, kwMinContent, kwMaxContent, kwFitContent,
    kwSubgrid, kwSpan, kwAutoFill, kwAutoFit, kwAutoFlow, kwMasonry, kwAnchorCenter,
    { boxes }
    kwContentBox, kwBorderBox, kwPaddingBox, kwMarginBox, kwFillBox, kwStrokeBox, kwViewBox,
    kwText, kwVisible, kwHidden, kwCollapse, kwScroll, kwClip, kwOverlay,
    kwSize, kwInlineSize, kwLayout, kwStyle, kwPaint, kwStrict, kwContain, kwCover,
    kwFill, kwScaleDown, kwSlice, kwClone,
    { text }
    kwJustify, kwJustifyAll, kwMatchParent, kwWebkitMatchParent, kwWebkitLeft, kwWebkitRight,
    kwWebkitCenter, kwCapitalize, kwUppercase, kwLowercase, kwFullWidth, kwFullSizeKana,
    kwUnderline, kwOverline, kwLineThrough, kwBlink, kwSolid, kwDouble, kwDotted, kwDashed,
    kwWavy, kwFromFont, kwSpellingError, kwGrammarError, kwEllipsis, kwLtr, kwRtl,
    kwEmbed, kwIsolate, kwBidiOverride, kwIsolateOverride, kwPlaintext,
    kwHorizontalTb, kwVerticalRl, kwVerticalLr, kwSidewaysRl, kwSidewaysLr,
    kwMixed, kwUpright, kwSideways, kwSub, kwSuper, kwTextTop, kwTextBottom, kwMiddle,
    kwPre, kwPreWrap, kwPreLine, kwBreakSpaces, kwPreserve, kwPreserveBreaks, kwPreserveSpaces,
    kwDiscard, kwBalance, kwPretty, kwStable, kwBreakWord, kwAnywhere, kwBreakAll, kwKeepAll,
    kwManual, kwLoose, kwInterWord, kwInterCharacter, kwOptimizespeed, kwOptimizelegibility,
    kwGeometricprecision, kwUnder,
    { fonts }
    kwSerif, kwSansSerif, kwMonospace, kwCursive, kwFantasy, kwSystemUi, kwUiSerif,
    kwUiSansSerif, kwUiMonospace, kwUiRounded, kwEmoji, kwFangsong,
    kwBold, kwBolder, kwLighter, kwItalic, kwOblique,
    kwXxSmall, kwXSmall, kwSmall, kwMedium, kwLarge, kwXLarge, kwXxLarge, kwXxxLarge,
    kwLarger, kwSmaller,
    kwUltraCondensed, kwExtraCondensed, kwCondensed, kwSemiCondensed, kwSemiExpanded,
    kwExpanded, kwExtraExpanded, kwUltraExpanded,
    kwSmallCaps, kwAllSmallCaps, kwPetiteCaps, kwAllPetiteCaps, kwUnicase, kwTitlingCaps,
    kwCaption, kwIcon, kwMenu, kwMessageBox, kwSmallCaption, kwStatusBar,
    kwCommonLigatures, kwNoCommonLigatures, kwDiscretionaryLigatures,
    kwNoDiscretionaryLigatures, kwHistoricalLigatures, kwNoHistoricalLigatures,
    kwContextual, kwNoContextual, kwLiningNums, kwOldstyleNums, kwProportionalNums,
    kwTabularNums, kwDiagonalFractions, kwStackedFractions, kwOrdinal, kwSlashedZero,
    kwOn, kwOff, kwSwap, kwFallback, kwOptional, kwExHeight, kwCapHeight, kwChWidth,
    kwIcWidth, kwIcHeight,
    { lists and generated content }
    kwDisc, kwCircle, kwSquare, kwDecimal, kwDecimalLeadingZero, kwLowerRoman, kwUpperRoman,
    kwLowerAlpha, kwUpperAlpha, kwLowerLatin, kwUpperLatin, kwLowerGreek, kwArmenian,
    kwGeorgian, kwHebrew, kwDisclosureOpen, kwDisclosureClosed, kwInside, kwOutside,
    kwOpenQuote, kwCloseQuote, kwNoOpenQuote, kwNoCloseQuote,
    { borders and backgrounds }
    kwGroove, kwRidge, kwInset, kwOutset, kwThin, kwThick,
    kwRepeat, kwRepeatX, kwRepeatY, kwNoRepeat, kwSpace, kwRound, kwLocal,
    { colors }
    kwCurrentcolor, kwTransparent,
    kwCanvas, kwCanvastext, kwLinktext, kwVisitedtext, kwActivetext, kwButtonface,
    kwButtontext, kwButtonborder, kwField, kwFieldtext, kwHighlight, kwHighlighttext,
    kwSelecteditem, kwSelecteditemtext, kwMark, kwMarktext, kwGraytext, kwAccentcolor,
    kwAccentcolortext,
    kwSrgb, kwSrgbLinear, kwDisplayP3, kwA98Rgb, kwProphotoRgb, kwRec2020, kwXyz, kwXyzD50,
    kwXyzD65, kwHsl, kwHwb, kwLab, kwLch, kwOklab, kwOklch,
    kwShorter, kwLonger, kwIncreasing, kwDecreasing, kwHue,
    kwR, kwG, kwB, kwH, kwS, kwL, kwW, kwC, kwA, kwAlpha, kwX, kwY, kwZ,
    { gradients and shapes }
    kwEllipse, kwClosestSide, kwClosestCorner, kwFarthestSide, kwFarthestCorner,
    { user interface }
    kwPointer, kwContextMenu, kwHelp, kwProgress, kwWait, kwCell, kwCrosshair,
    kwVerticalText, kwAlias, kwCopy, kwMove, kwNoDrop, kwNotAllowed, kwGrab, kwGrabbing,
    kwEResize, kwNResize, kwNeResize, kwNwResize, kwSResize, kwSeResize, kwSwResize,
    kwWResize, kwEwResize, kwNsResize, kwNeswResize, kwNwseResize, kwColResize, kwRowResize,
    kwAllScroll, kwZoomIn, kwZoomOut,
    kwVisiblePainted, kwVisibleFill, kwVisibleStroke, kwPainted, kwStroke,
    kwHorizontal, kwVertical, kwInlineAxis, kwBlockAxis, kwCrispEdges, kwPixelated, kwSmooth, kwHighQuality,
    kwLight, kwDark, kwPanX, kwPanY, kwPinchZoom, kwManipulation, kwScrollPosition,
    kwButton, kwTextfield, kwMenulistButton, kwSearchfield, kwTextarea, kwCheckbox, kwRadio,
    kwMenulist, kwListbox, kwMeter, kwProgressBar, kwPushButton, kwSquareButton, kwBothEdges,
    { SVG painting }
    kwNonzero, kwEvenodd, kwButt, kwMiter, kwMiterClip, kwBevel, kwArcs, kwContextFill, kwContextStroke,
    kwMarkers, kwNonScalingStroke,
    { tables }
    kwSeparate, kwShow, kwHide,
    { transitions and animations }
    kwEase, kwLinear, kwEaseIn, kwEaseOut, kwEaseInOut, kwStepStart, kwStepEnd, kwJumpStart,
    kwJumpEnd, kwJumpNone, kwJumpBoth, kwInfinite, kwReverse, kwAlternate, kwAlternateReverse,
    kwForwards, kwBackwards, kwRunning, kwPaused, kwAllowDiscrete, kwReplace, kwAdd,
    kwAccumulate,
    { transforms and compositing }
    kwFlat, kwPreserve3d, kwMultiply, kwScreen, kwDarken, kwLighten, kwColorDodge,
    kwColorBurn, kwHardLight, kwSoftLight, kwDifference, kwExclusion, kwSaturation, kwColor,
    kwLuminosity, kwPlusLighter, kwPlusDarker, kwLuminance, kwMatchSource, kwNoClip,
    { media queries }
    kwPrint, kwPortrait, kwLandscape, kwReduce, kwNoPreference, kwFine, kwCoarse,
    kwHover, kwInterlace, kwProgressive, kwFast, kwSlow, kwStandard, kwHigh, kwMore, kwLess,
    kwCustom, kwActive, kwInverted, kwBrowser, kwFullscreen, kwStandalone, kwMinimalUi,
    kwPictureInPicture, kwP3, kwEnabled, kwInitialOnly, kwSpeech, kwTty, kwTv, kwProjection,
    kwHandheld, kwBraille, kwEmbossed, kwAural, kwPaged,
    { math }
    kwE, kwPi, kwInfinity, kwNan, kwNearest, kwUp, kwDown, kwToZero
  );

const
  KeywordCount = Ord(High(TCssKeyword)) + 1;

{ The keyword's CSS spelling. }
function KeywordName(Keyword: TCssKeyword): string;
{ The keyword an atom names, or kwInvalid (atoms are Css.Atoms'). }
function KeywordOfAtom(Atom: LongWord): TCssKeyword; inline;
{ Whether Keyword is one of Options (there are too many keywords for
  Pascal sets). }
function KeywordIn(Keyword: TCssKeyword; const Options: array of TCssKeyword): Boolean;

implementation

uses
  TypInfo;

function KeywordName(Keyword: TCssKeyword): string;
var
  Identifier: string;
  Index: Integer;
  Character: Char;
begin
  Result := '';
  if Keyword = kwInvalid then
    Exit;
  Identifier := GetEnumName(TypeInfo(TCssKeyword), Ord(Keyword));
  { Drop the "kw" prefix. }
  Delete(Identifier, 1, 2);
  if Copy(Identifier, 1, 6) = 'Webkit' then
  begin
    Result := '-webkit';
    Delete(Identifier, 1, 6);
  end;
  for Index := 1 to Length(Identifier) do
  begin
    Character := Identifier[Index];
    if Character in ['A'..'Z'] then
    begin
      if Result <> '' then
        Result := Result + '-';
      Result := Result + Chr(Ord(Character) + 32);
    end
    else
      Result := Result + Character;
  end;
  { The one keyword with a hyphen before a digit. }
  if Result = 'preserve3d' then
    Result := 'preserve-3d';
end;

function KeywordIn(Keyword: TCssKeyword; const Options: array of TCssKeyword): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Options) do
    if Options[Index] = Keyword then
      Exit(True);
  Result := False;
end;

function KeywordOfAtom(Atom: LongWord): TCssKeyword;
begin
  if Atom < KeywordCount then
    Result := TCssKeyword(Atom)
  else
    Result := kwInvalid;
end;

end.

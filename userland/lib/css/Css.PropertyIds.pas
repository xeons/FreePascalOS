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
  The properties the style engine knows: their ids, the groups their
  computed values are stored in, and how each is computed and
  animated.

  A property's name comes from its identifier (cpBorderTopLeftRadius is
  "border-top-left-radius"). Longhands come first: physical ones with
  storage in a style struct, then the logical ones (stored in the
  physical property they map to for the element's writing mode), then
  the shorthands. Css.PropertyTable holds each one's row.
}
unit Css.PropertyIds;

{$mode objfpc}
{$H+}

interface

type
  { Groups of computed values stored together (and shared) like
    Gecko's and Servo's style structs. A group is either all inherited
    or all not inherited, so inheriting one is copying a pointer. }
  TCssPropertyGroup = (pgNone,
    { inherited }
    pgFont, pgInheritedText, pgInheritedBox, pgInheritedUi, pgList, pgInheritedTable, pgInheritedSvg,
    { not inherited }
    pgBox, pgPosition, pgMargin, pgPadding, pgBorder, pgOutline, pgBackground, pgEffects,
    pgText, pgContent, pgTable, pgColumn, pgUi, pgAnimation, pgSvg);

  TCssStructGroup = pgFont..pgSvg;

  { How a specified value becomes a computed value. }
  TCssComputeKind = (
    { a keyword or a value kept as it is }
    cmpKeyword,
    { lengths absolute (px), percentages kept, numbers and keywords as they are }
    cmpLength,
    { a color; currentcolor stays currentcolor }
    cmpColor,
    { the color property: currentcolor is the parent's color }
    cmpForegroundColor,
    cmpNumber, cmpInteger,
    { thin, medium, thick and lengths, as px }
    cmpLineWidth,
    cmpFontSize, cmpFontWeight, cmpLineHeight,
    { a number from 0 to 1 (percentages divided by 100) }
    cmpOpacity,
    { display, blockified where the spec says }
    cmpDisplay,
    { any other value tree, its lengths made absolute }
    cmpValue);

  TCssAnimationType = (atNone, atDiscrete, atLength, atNumber, atInteger, atColor, atVisibility,
    atFontWeight, atTransform, atShadowList, atByComputedValue);

  TCssPropertyId = (cpInvalid,
    { font }
    cpFontFamily, cpFontSize, cpFontWeight, cpFontStyle, cpFontStretch, cpFontVariantCaps,
    cpFontVariantLigatures, cpFontVariantNumeric, cpFontVariantEastAsian, cpFontVariantPosition,
    cpFontKerning, cpFontOpticalSizing, cpFontFeatureSettings, cpFontVariationSettings,
    cpFontSizeAdjust, cpLineHeight,
    { inherited text }
    cpColor, cpTextAlign, cpTextAlignLast, cpTextIndent, cpTextTransform, cpLetterSpacing,
    cpWordSpacing, cpWhiteSpace, cpWordBreak, cpOverflowWrap, cpHyphens, cpTabSize, cpLineBreak,
    cpTextJustify, cpTextShadow, cpTextUnderlinePosition, cpTextDecorationSkipInk,
    cpTextRendering,
    { inherited box }
    cpDirection, cpWritingMode, cpTextOrientation, cpVisibility, cpImageRendering, cpOrphans,
    cpWidows,
    { inherited user interface }
    cpCursor, cpPointerEvents, cpCaretColor, cpAccentColor, cpColorScheme,
    { lists }
    cpListStyleType, cpListStylePosition, cpListStyleImage, cpQuotes,
    { inherited table }
    cpBorderCollapse, cpBorderSpacing, cpCaptionSide, cpEmptyCells,
    { box }
    cpDisplay, cpPosition, cpFloat, cpClear, cpOverflowX, cpOverflowY, cpBoxSizing,
    cpVerticalAlign, cpTransform, cpTransformOrigin, cpTransformBox, cpTransformStyle,
    cpPerspective, cpPerspectiveOrigin, cpBackfaceVisibility, cpTranslate, cpRotate, cpScale,
    cpWillChange, cpContain, cpContentVisibility, cpContainerType, cpContainerName, cpAppearance,
    cpScrollBehavior,
    { position, sizing, flex and grid }
    cpTop, cpRight, cpBottom, cpLeft, cpWidth, cpHeight, cpMinWidth, cpMinHeight, cpMaxWidth,
    cpMaxHeight, cpZIndex, cpFlexDirection, cpFlexWrap, cpFlexGrow, cpFlexShrink, cpFlexBasis,
    cpOrder, cpJustifyContent, cpAlignContent, cpAlignItems, cpAlignSelf, cpJustifyItems,
    cpJustifySelf, cpRowGap, cpColumnGap, cpGridTemplateColumns, cpGridTemplateRows,
    cpGridTemplateAreas, cpGridAutoColumns, cpGridAutoRows, cpGridAutoFlow, cpGridRowStart,
    cpGridRowEnd, cpGridColumnStart, cpGridColumnEnd, cpAspectRatio, cpObjectFit,
    cpObjectPosition,
    { margins and padding }
    cpMarginTop, cpMarginRight, cpMarginBottom, cpMarginLeft,
    cpPaddingTop, cpPaddingRight, cpPaddingBottom, cpPaddingLeft,
    { borders }
    cpBorderTopWidth, cpBorderRightWidth, cpBorderBottomWidth, cpBorderLeftWidth,
    cpBorderTopStyle, cpBorderRightStyle, cpBorderBottomStyle, cpBorderLeftStyle,
    cpBorderTopColor, cpBorderRightColor, cpBorderBottomColor, cpBorderLeftColor,
    cpBorderTopLeftRadius, cpBorderTopRightRadius, cpBorderBottomRightRadius,
    cpBorderBottomLeftRadius, cpBorderImageSource, cpBorderImageSlice, cpBorderImageWidth,
    cpBorderImageOutset, cpBorderImageRepeat,
    { outline }
    cpOutlineWidth, cpOutlineStyle, cpOutlineColor, cpOutlineOffset,
    { backgrounds }
    cpBackgroundColor, cpBackgroundImage, cpBackgroundPositionX, cpBackgroundPositionY,
    cpBackgroundSize, cpBackgroundRepeat, cpBackgroundAttachment, cpBackgroundClip,
    cpBackgroundOrigin, cpBackgroundBlendMode,
    { effects }
    cpOpacity, cpBoxShadow, cpFilter, cpBackdropFilter, cpMixBlendMode, cpIsolation, cpClipPath,
    cpClip,
    { masking }
    cpMaskImage, cpMaskPositionX, cpMaskPositionY, cpMaskSize, cpMaskRepeat, cpMaskOrigin, cpMaskClip,
    cpMaskMode,
    { text decoration }
    cpTextDecorationLine, cpTextDecorationStyle, cpTextDecorationColor,
    cpTextDecorationThickness, cpTextUnderlineOffset, cpTextOverflow, cpUnicodeBidi,
    { generated content }
    cpContent, cpCounterReset, cpCounterIncrement, cpCounterSet,
    { table }
    cpTableLayout,
    { columns }
    cpColumnCount, cpColumnWidth, cpColumnRuleWidth, cpColumnRuleStyle, cpColumnRuleColor,
    cpColumnSpan, cpColumnFill,
    { user interface }
    cpUserSelect, cpResize, cpTouchAction, cpScrollbarWidth, cpScrollbarGutter, cpScrollbarColor,
    { SVG painting, inherited }
    cpFill, cpFillRule, cpFillOpacity, cpStroke, cpStrokeWidth, cpStrokeLinecap, cpStrokeLinejoin,
    cpStrokeMiterlimit, cpStrokeDasharray, cpStrokeDashoffset, cpStrokeOpacity, cpClipRule, cpTextAnchor,
    cpPaintOrder,
    { SVG, not inherited }
    cpStopColor, cpStopOpacity, cpVectorEffect,
    { transitions and animations }
    cpTransitionProperty, cpTransitionDuration, cpTransitionTimingFunction, cpTransitionDelay,
    cpTransitionBehavior, cpAnimationName, cpAnimationDuration, cpAnimationTimingFunction,
    cpAnimationDelay, cpAnimationIterationCount, cpAnimationDirection, cpAnimationFillMode,
    cpAnimationPlayState, cpAnimationComposition,

    { logical longhands }
    cpMarginBlockStart, cpMarginBlockEnd, cpMarginInlineStart, cpMarginInlineEnd,
    cpPaddingBlockStart, cpPaddingBlockEnd, cpPaddingInlineStart, cpPaddingInlineEnd,
    cpInsetBlockStart, cpInsetBlockEnd, cpInsetInlineStart, cpInsetInlineEnd,
    cpBorderBlockStartWidth, cpBorderBlockEndWidth, cpBorderInlineStartWidth,
    cpBorderInlineEndWidth, cpBorderBlockStartStyle, cpBorderBlockEndStyle,
    cpBorderInlineStartStyle, cpBorderInlineEndStyle, cpBorderBlockStartColor,
    cpBorderBlockEndColor, cpBorderInlineStartColor, cpBorderInlineEndColor,
    cpInlineSize, cpBlockSize, cpMinInlineSize, cpMinBlockSize, cpMaxInlineSize, cpMaxBlockSize,
    cpBorderStartStartRadius, cpBorderStartEndRadius, cpBorderEndStartRadius,
    cpBorderEndEndRadius,

    { shorthands }
    cpMargin, cpPadding, cpInset, cpBorder, cpBorderTop, cpBorderRight, cpBorderBottom,
    cpBorderLeft, cpBorderWidth, cpBorderStyle, cpBorderColor, cpBorderRadius, cpBorderImage,
    cpBorderBlock, cpBorderInline, cpBorderBlockStart, cpBorderBlockEnd, cpBorderInlineStart,
    cpBorderInlineEnd, cpBorderBlockWidth, cpBorderBlockStyle, cpBorderBlockColor,
    cpBorderInlineWidth, cpBorderInlineStyle, cpBorderInlineColor, cpMarginBlock, cpMarginInline,
    cpPaddingBlock, cpPaddingInline, cpInsetBlock, cpInsetInline, cpOutline, cpBackground,
    cpBackgroundPosition, cpMask, cpMaskPosition, cpFont, cpFontVariant, cpFlex, cpFlexFlow, cpGrid, cpGridTemplate,
    cpGridRow, cpGridColumn, cpGridArea, cpGap, cpPlaceContent, cpPlaceItems, cpPlaceSelf,
    cpOverflow, cpListStyle, cpTextDecoration, cpTransition, cpAnimation, cpColumns,
    cpColumnRule, cpContainer,

    { a custom property (--name); its name is kept with the declaration }
    cpCustom);

  TCssPropertyIdArray = array of TCssPropertyId;
  TCssLonghandId = Succ(cpInvalid)..Pred(cpMargin);
  TCssPhysicalId = Succ(cpInvalid)..cpAnimationComposition;

const
  FirstLogical = cpMarginBlockStart;
  LastLogical = cpBorderEndEndRadius;
  FirstShorthand = cpMargin;
  LastShorthand = cpContainer;
  LonghandCount = Ord(Pred(cpMargin));
  PhysicalCount = Ord(cpAnimationComposition);

  InheritedGroups = [pgFont, pgInheritedText, pgInheritedBox, pgInheritedUi, pgList, pgInheritedTable,
    pgInheritedSvg];

type
  TCssPropertyInfo = record
    Group: TCssPropertyGroup;
    Initial: string;
    { What the value may be: alternatives of keywords and <types>
      separated by '|'; a leading '#' makes it a comma separated list
      of them; keywords in braces are any of those keywords, each once, in any
      order; '@name' is a parsing routine of Css.PropertyParsers. }
    Grammar: string;
    Compute: TCssComputeKind;
    Animation: TCssAnimationType;
  end;

function IsShorthand(Id: TCssPropertyId): Boolean; inline;
function IsLogical(Id: TCssPropertyId): Boolean; inline;
function IsLonghand(Id: TCssPropertyId): Boolean; inline;

implementation

function IsShorthand(Id: TCssPropertyId): Boolean;
begin
  Result := (Id >= FirstShorthand) and (Id <= LastShorthand);
end;

function IsLogical(Id: TCssPropertyId): Boolean;
begin
  Result := (Id >= FirstLogical) and (Id <= LastLogical);
end;

function IsLonghand(Id: TCssPropertyId): Boolean;
begin
  Result := (Id > cpInvalid) and (Id < FirstShorthand);
end;

end.

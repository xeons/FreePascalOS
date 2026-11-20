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
  The property table: one row per property id (Css.PropertyIds), in
  the same order: its group, initial value, grammar, how it is
  computed and how it animates. The initial values are parsed with the
  same grammars when the library starts.
}
unit Css.PropertyTable;

{$mode objfpc}
{$H+}

interface

uses
  Css.PropertyIds;

const
  BorderStyles = 'none | hidden | dotted | dashed | solid | double | groove | ridge | inset | outset';
  OutlineStyles = 'auto | none | dotted | dashed | solid | double | groove | ridge | inset | outset';
  BlendModes = 'normal | multiply | screen | overlay | darken | lighten | color-dodge | color-burn | ' +
    'hard-light | soft-light | difference | exclusion | hue | saturation | color | luminosity';
  LengthPercentageAuto = 'auto | <length-percentage>';
  SizeGrammar = '@size';

  PropertyTable: array[TCssPropertyId] of TCssPropertyInfo = (
    { cpInvalid }
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    { font }
    (Group: pgFont; Initial: 'serif'; Grammar: '@font-family'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgFont; Initial: 'medium'; Grammar: 'xx-small | x-small | small | medium | large | x-large | xx-large | ' +
      'xxx-large | larger | smaller | <length-percentage+>'; Compute: cmpFontSize; Animation: atLength),
    (Group: pgFont; Initial: 'normal'; Grammar: 'normal | bold | bolder | lighter | <font-weight>';
      Compute: cmpFontWeight; Animation: atFontWeight),
    (Group: pgFont; Initial: 'normal'; Grammar: '@font-style'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgFont; Initial: 'normal'; Grammar: 'normal | ultra-condensed | extra-condensed | condensed | ' +
      'semi-condensed | semi-expanded | expanded | extra-expanded | ultra-expanded | <percentage+>';
      Compute: cmpKeyword; Animation: atNumber),
    (Group: pgFont; Initial: 'normal'; Grammar: 'normal | small-caps | all-small-caps | petite-caps | ' +
      'all-petite-caps | unicase | titling-caps'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgFont; Initial: 'normal'; Grammar: 'normal | none | {common-ligatures no-common-ligatures ' +
      'discretionary-ligatures no-discretionary-ligatures historical-ligatures no-historical-ligatures ' +
      'contextual no-contextual}'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgFont; Initial: 'normal'; Grammar: 'normal | {lining-nums oldstyle-nums proportional-nums ' +
      'tabular-nums diagonal-fractions stacked-fractions ordinal slashed-zero}'; Compute: cmpKeyword;
      Animation: atDiscrete),
    (Group: pgFont; Initial: 'normal'; Grammar: 'normal | {full-width ruby}'; Compute: cmpKeyword;
      Animation: atDiscrete),
    (Group: pgFont; Initial: 'normal'; Grammar: 'normal | sub | super'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgFont; Initial: 'auto'; Grammar: 'auto | normal | none'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgFont; Initial: 'auto'; Grammar: 'auto | none'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgFont; Initial: 'normal'; Grammar: '@font-feature-settings'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgFont; Initial: 'normal'; Grammar: '@font-variation-settings'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgFont; Initial: 'none'; Grammar: 'none | from-font | <number+>'; Compute: cmpNumber; Animation: atNumber),
    (Group: pgFont; Initial: 'normal'; Grammar: 'normal | <number+> | <length-percentage+>';
      Compute: cmpLineHeight; Animation: atLength),
    { inherited text }
    (Group: pgInheritedText; Initial: 'canvastext'; Grammar: '<color>'; Compute: cmpForegroundColor;
      Animation: atColor),
    (Group: pgInheritedText; Initial: 'start'; Grammar: 'start | end | left | right | center | justify | ' +
      'match-parent | justify-all | -webkit-left | -webkit-right | -webkit-center | -webkit-match-parent';
      Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgInheritedText; Initial: 'auto'; Grammar: 'auto | start | end | left | right | center | justify | ' +
      'match-parent'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgInheritedText; Initial: '0'; Grammar: '<length-percentage>'; Compute: cmpLength; Animation: atLength),
    (Group: pgInheritedText; Initial: 'none'; Grammar: 'none | capitalize | uppercase | lowercase | full-width | ' +
      'full-size-kana'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgInheritedText; Initial: 'normal'; Grammar: 'normal | <length-percentage>'; Compute: cmpLength;
      Animation: atLength),
    (Group: pgInheritedText; Initial: 'normal'; Grammar: 'normal | <length-percentage>'; Compute: cmpLength;
      Animation: atLength),
    (Group: pgInheritedText; Initial: 'normal'; Grammar: 'normal | pre | nowrap | pre-wrap | pre-line | break-spaces';
      Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgInheritedText; Initial: 'normal'; Grammar: 'normal | break-all | keep-all | break-word';
      Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgInheritedText; Initial: 'normal'; Grammar: 'normal | break-word | anywhere'; Compute: cmpKeyword;
      Animation: atDiscrete),
    (Group: pgInheritedText; Initial: 'manual'; Grammar: 'none | manual | auto'; Compute: cmpKeyword;
      Animation: atDiscrete),
    (Group: pgInheritedText; Initial: '8'; Grammar: '<number+> | <length+>'; Compute: cmpLength; Animation: atLength),
    (Group: pgInheritedText; Initial: 'auto'; Grammar: 'auto | loose | normal | strict | anywhere';
      Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgInheritedText; Initial: 'auto'; Grammar: 'auto | none | inter-word | inter-character';
      Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgInheritedText; Initial: 'none'; Grammar: '@text-shadow'; Compute: cmpValue; Animation: atShadowList),
    (Group: pgInheritedText; Initial: 'auto'; Grammar: 'auto | {from-font under left right}'; Compute: cmpKeyword;
      Animation: atDiscrete),
    (Group: pgInheritedText; Initial: 'auto'; Grammar: 'auto | none | all'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgInheritedText; Initial: 'auto'; Grammar: 'auto | optimizespeed | optimizelegibility | geometricprecision'; Compute: cmpKeyword; Animation: atDiscrete),
    { inherited box }
    (Group: pgInheritedBox; Initial: 'ltr'; Grammar: 'ltr | rtl'; Compute: cmpKeyword; Animation: atNone),
    (Group: pgInheritedBox; Initial: 'horizontal-tb'; Grammar: 'horizontal-tb | vertical-rl | vertical-lr | ' +
      'sideways-rl | sideways-lr'; Compute: cmpKeyword; Animation: atNone),
    (Group: pgInheritedBox; Initial: 'mixed'; Grammar: 'mixed | upright | sideways'; Compute: cmpKeyword;
      Animation: atNone),
    (Group: pgInheritedBox; Initial: 'visible'; Grammar: 'visible | hidden | collapse'; Compute: cmpKeyword;
      Animation: atVisibility),
    (Group: pgInheritedBox; Initial: 'auto'; Grammar: 'auto | smooth | high-quality | crisp-edges | pixelated';
      Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgInheritedBox; Initial: '2'; Grammar: '<integer1>'; Compute: cmpInteger; Animation: atInteger),
    (Group: pgInheritedBox; Initial: '2'; Grammar: '<integer1>'; Compute: cmpInteger; Animation: atInteger),
    { inherited user interface }
    (Group: pgInheritedUi; Initial: 'auto'; Grammar: '@cursor'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgInheritedUi; Initial: 'auto'; Grammar: 'auto | none | visible-painted | visible-fill | ' +
      'visible-stroke | visible | painted | fill | stroke | all'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgInheritedUi; Initial: 'auto'; Grammar: 'auto | <color>'; Compute: cmpColor; Animation: atColor),
    (Group: pgInheritedUi; Initial: 'auto'; Grammar: 'auto | <color>'; Compute: cmpColor; Animation: atColor),
    (Group: pgInheritedUi; Initial: 'normal'; Grammar: '@color-scheme'; Compute: cmpValue; Animation: atDiscrete),
    { lists }
    (Group: pgList; Initial: 'disc'; Grammar: '@list-style-type'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgList; Initial: 'outside'; Grammar: 'inside | outside'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgList; Initial: 'none'; Grammar: 'none | <image>'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgList; Initial: 'auto'; Grammar: '@quotes'; Compute: cmpValue; Animation: atDiscrete),
    { inherited table }
    (Group: pgInheritedTable; Initial: 'separate'; Grammar: 'separate | collapse'; Compute: cmpKeyword;
      Animation: atDiscrete),
    (Group: pgInheritedTable; Initial: '0'; Grammar: '@border-spacing'; Compute: cmpValue; Animation: atLength),
    (Group: pgInheritedTable; Initial: 'top'; Grammar: 'top | bottom'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgInheritedTable; Initial: 'show'; Grammar: 'show | hide'; Compute: cmpKeyword; Animation: atDiscrete),
    { box }
    (Group: pgBox; Initial: 'inline'; Grammar: '@display'; Compute: cmpDisplay; Animation: atDiscrete),
    (Group: pgBox; Initial: 'static'; Grammar: 'static | relative | absolute | fixed | sticky'; Compute: cmpKeyword;
      Animation: atDiscrete),
    (Group: pgBox; Initial: 'none'; Grammar: 'none | left | right | inline-start | inline-end'; Compute: cmpKeyword;
      Animation: atDiscrete),
    (Group: pgBox; Initial: 'none'; Grammar: 'none | left | right | both | inline-start | inline-end';
      Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgBox; Initial: 'visible'; Grammar: 'visible | hidden | clip | scroll | auto'; Compute: cmpKeyword;
      Animation: atDiscrete),
    (Group: pgBox; Initial: 'visible'; Grammar: 'visible | hidden | clip | scroll | auto'; Compute: cmpKeyword;
      Animation: atDiscrete),
    (Group: pgBox; Initial: 'content-box'; Grammar: 'content-box | border-box'; Compute: cmpKeyword;
      Animation: atDiscrete),
    (Group: pgBox; Initial: 'baseline'; Grammar: 'baseline | sub | super | text-top | text-bottom | middle | top | ' +
      'bottom | <length-percentage>'; Compute: cmpLength; Animation: atLength),
    (Group: pgBox; Initial: 'none'; Grammar: '@transform'; Compute: cmpValue; Animation: atTransform),
    (Group: pgBox; Initial: '50% 50%'; Grammar: '@transform-origin'; Compute: cmpValue; Animation: atLength),
    (Group: pgBox; Initial: 'view-box'; Grammar: 'content-box | border-box | fill-box | stroke-box | view-box';
      Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgBox; Initial: 'flat'; Grammar: 'flat | preserve-3d'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgBox; Initial: 'none'; Grammar: 'none | <length+>'; Compute: cmpLength; Animation: atLength),
    (Group: pgBox; Initial: '50% 50%'; Grammar: '@position'; Compute: cmpValue; Animation: atLength),
    (Group: pgBox; Initial: 'visible'; Grammar: 'visible | hidden'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgBox; Initial: 'none'; Grammar: '@translate'; Compute: cmpValue; Animation: atTransform),
    (Group: pgBox; Initial: 'none'; Grammar: '@rotate'; Compute: cmpValue; Animation: atTransform),
    (Group: pgBox; Initial: 'none'; Grammar: '@scale'; Compute: cmpValue; Animation: atTransform),
    (Group: pgBox; Initial: 'auto'; Grammar: '@will-change'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgBox; Initial: 'none'; Grammar: 'none | strict | content | {size inline-size layout style paint}';
      Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgBox; Initial: 'visible'; Grammar: 'visible | auto | hidden'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgBox; Initial: 'normal'; Grammar: 'normal | size | inline-size'; Compute: cmpKeyword;
      Animation: atDiscrete),
    (Group: pgBox; Initial: 'none'; Grammar: '@container-name'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgBox; Initial: 'none'; Grammar: 'none | auto | menulist-button | textfield | button | checkbox | ' +
      'radio | menulist | listbox | meter | progress-bar | push-button | searchfield | textarea | ' +
      'square-button'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgBox; Initial: 'auto'; Grammar: 'auto | smooth'; Compute: cmpKeyword; Animation: atDiscrete),
    { position, sizing, flex and grid }
    (Group: pgPosition; Initial: 'auto'; Grammar: LengthPercentageAuto; Compute: cmpLength; Animation: atLength),
    (Group: pgPosition; Initial: 'auto'; Grammar: LengthPercentageAuto; Compute: cmpLength; Animation: atLength),
    (Group: pgPosition; Initial: 'auto'; Grammar: LengthPercentageAuto; Compute: cmpLength; Animation: atLength),
    (Group: pgPosition; Initial: 'auto'; Grammar: LengthPercentageAuto; Compute: cmpLength; Animation: atLength),
    (Group: pgPosition; Initial: 'auto'; Grammar: SizeGrammar; Compute: cmpLength; Animation: atLength),
    (Group: pgPosition; Initial: 'auto'; Grammar: SizeGrammar; Compute: cmpLength; Animation: atLength),
    (Group: pgPosition; Initial: 'auto'; Grammar: SizeGrammar; Compute: cmpLength; Animation: atLength),
    (Group: pgPosition; Initial: 'auto'; Grammar: SizeGrammar; Compute: cmpLength; Animation: atLength),
    (Group: pgPosition; Initial: 'none'; Grammar: '@max-size'; Compute: cmpLength; Animation: atLength),
    (Group: pgPosition; Initial: 'none'; Grammar: '@max-size'; Compute: cmpLength; Animation: atLength),
    (Group: pgPosition; Initial: 'auto'; Grammar: 'auto | <integer>'; Compute: cmpInteger; Animation: atInteger),
    (Group: pgPosition; Initial: 'row'; Grammar: 'row | row-reverse | column | column-reverse'; Compute: cmpKeyword;
      Animation: atDiscrete),
    (Group: pgPosition; Initial: 'nowrap'; Grammar: 'nowrap | wrap | wrap-reverse'; Compute: cmpKeyword;
      Animation: atDiscrete),
    (Group: pgPosition; Initial: '0'; Grammar: '<number+>'; Compute: cmpNumber; Animation: atNumber),
    (Group: pgPosition; Initial: '1'; Grammar: '<number+>'; Compute: cmpNumber; Animation: atNumber),
    (Group: pgPosition; Initial: 'auto'; Grammar: '@flex-basis'; Compute: cmpLength; Animation: atLength),
    (Group: pgPosition; Initial: '0'; Grammar: '<integer>'; Compute: cmpInteger; Animation: atInteger),
    (Group: pgPosition; Initial: 'normal'; Grammar: '@content-alignment'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgPosition; Initial: 'normal'; Grammar: '@content-alignment'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgPosition; Initial: 'normal'; Grammar: '@items-alignment'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgPosition; Initial: 'auto'; Grammar: '@self-alignment'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgPosition; Initial: 'legacy'; Grammar: '@justify-items'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgPosition; Initial: 'auto'; Grammar: '@self-alignment'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgPosition; Initial: 'normal'; Grammar: 'normal | <length-percentage+>'; Compute: cmpLength;
      Animation: atLength),
    (Group: pgPosition; Initial: 'normal'; Grammar: 'normal | <length-percentage+>'; Compute: cmpLength;
      Animation: atLength),
    (Group: pgPosition; Initial: 'none'; Grammar: '@track-list'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgPosition; Initial: 'none'; Grammar: '@track-list'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgPosition; Initial: 'none'; Grammar: '@grid-template-areas'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgPosition; Initial: 'auto'; Grammar: '@track-sizes'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgPosition; Initial: 'auto'; Grammar: '@track-sizes'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgPosition; Initial: 'row'; Grammar: '@grid-auto-flow'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgPosition; Initial: 'auto'; Grammar: '@grid-line'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgPosition; Initial: 'auto'; Grammar: '@grid-line'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgPosition; Initial: 'auto'; Grammar: '@grid-line'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgPosition; Initial: 'auto'; Grammar: '@grid-line'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgPosition; Initial: 'auto'; Grammar: '@aspect-ratio'; Compute: cmpValue; Animation: atNumber),
    (Group: pgPosition; Initial: 'fill'; Grammar: 'fill | contain | cover | none | scale-down'; Compute: cmpKeyword;
      Animation: atDiscrete),
    (Group: pgPosition; Initial: '50% 50%'; Grammar: '@position'; Compute: cmpValue; Animation: atLength),
    { margins }
    (Group: pgMargin; Initial: '0'; Grammar: LengthPercentageAuto; Compute: cmpLength; Animation: atLength),
    (Group: pgMargin; Initial: '0'; Grammar: LengthPercentageAuto; Compute: cmpLength; Animation: atLength),
    (Group: pgMargin; Initial: '0'; Grammar: LengthPercentageAuto; Compute: cmpLength; Animation: atLength),
    (Group: pgMargin; Initial: '0'; Grammar: LengthPercentageAuto; Compute: cmpLength; Animation: atLength),
    { padding }
    (Group: pgPadding; Initial: '0'; Grammar: '<length-percentage+>'; Compute: cmpLength; Animation: atLength),
    (Group: pgPadding; Initial: '0'; Grammar: '<length-percentage+>'; Compute: cmpLength; Animation: atLength),
    (Group: pgPadding; Initial: '0'; Grammar: '<length-percentage+>'; Compute: cmpLength; Animation: atLength),
    (Group: pgPadding; Initial: '0'; Grammar: '<length-percentage+>'; Compute: cmpLength; Animation: atLength),
    { borders }
    (Group: pgBorder; Initial: 'medium'; Grammar: '<line-width>'; Compute: cmpLineWidth; Animation: atLength),
    (Group: pgBorder; Initial: 'medium'; Grammar: '<line-width>'; Compute: cmpLineWidth; Animation: atLength),
    (Group: pgBorder; Initial: 'medium'; Grammar: '<line-width>'; Compute: cmpLineWidth; Animation: atLength),
    (Group: pgBorder; Initial: 'medium'; Grammar: '<line-width>'; Compute: cmpLineWidth; Animation: atLength),
    (Group: pgBorder; Initial: 'none'; Grammar: BorderStyles; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgBorder; Initial: 'none'; Grammar: BorderStyles; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgBorder; Initial: 'none'; Grammar: BorderStyles; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgBorder; Initial: 'none'; Grammar: BorderStyles; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgBorder; Initial: 'currentcolor'; Grammar: '<color>'; Compute: cmpColor; Animation: atColor),
    (Group: pgBorder; Initial: 'currentcolor'; Grammar: '<color>'; Compute: cmpColor; Animation: atColor),
    (Group: pgBorder; Initial: 'currentcolor'; Grammar: '<color>'; Compute: cmpColor; Animation: atColor),
    (Group: pgBorder; Initial: 'currentcolor'; Grammar: '<color>'; Compute: cmpColor; Animation: atColor),
    (Group: pgBorder; Initial: '0'; Grammar: '@radius-corner'; Compute: cmpValue; Animation: atLength),
    (Group: pgBorder; Initial: '0'; Grammar: '@radius-corner'; Compute: cmpValue; Animation: atLength),
    (Group: pgBorder; Initial: '0'; Grammar: '@radius-corner'; Compute: cmpValue; Animation: atLength),
    (Group: pgBorder; Initial: '0'; Grammar: '@radius-corner'; Compute: cmpValue; Animation: atLength),
    (Group: pgBorder; Initial: 'none'; Grammar: 'none | <image>'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgBorder; Initial: '100%'; Grammar: '@border-image-slice'; Compute: cmpValue; Animation: atNumber),
    (Group: pgBorder; Initial: '1'; Grammar: '@border-image-width'; Compute: cmpValue; Animation: atLength),
    (Group: pgBorder; Initial: '0'; Grammar: '@border-image-outset'; Compute: cmpValue; Animation: atLength),
    (Group: pgBorder; Initial: 'stretch'; Grammar: '@border-image-repeat'; Compute: cmpValue; Animation: atDiscrete),
    { outline }
    (Group: pgOutline; Initial: 'medium'; Grammar: '<line-width>'; Compute: cmpLineWidth; Animation: atLength),
    (Group: pgOutline; Initial: 'none'; Grammar: OutlineStyles; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgOutline; Initial: 'auto'; Grammar: 'auto | <color>'; Compute: cmpColor; Animation: atColor),
    (Group: pgOutline; Initial: '0'; Grammar: '<length>'; Compute: cmpLength; Animation: atLength),
    { backgrounds }
    (Group: pgBackground; Initial: 'transparent'; Grammar: '<color>'; Compute: cmpColor; Animation: atColor),
    (Group: pgBackground; Initial: 'none'; Grammar: '#none | <image>'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgBackground; Initial: '0%'; Grammar: '@background-position-x'; Compute: cmpValue; Animation: atLength),
    (Group: pgBackground; Initial: '0%'; Grammar: '@background-position-y'; Compute: cmpValue; Animation: atLength),
    (Group: pgBackground; Initial: 'auto'; Grammar: '@background-size'; Compute: cmpValue; Animation: atLength),
    (Group: pgBackground; Initial: 'repeat'; Grammar: '@background-repeat'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgBackground; Initial: 'scroll'; Grammar: '#scroll | fixed | local'; Compute: cmpValue;
      Animation: atDiscrete),
    (Group: pgBackground; Initial: 'border-box'; Grammar: '#border-box | padding-box | content-box | text';
      Compute: cmpValue; Animation: atDiscrete),
    (Group: pgBackground; Initial: 'padding-box'; Grammar: '#border-box | padding-box | content-box';
      Compute: cmpValue; Animation: atDiscrete),
    (Group: pgBackground; Initial: 'normal'; Grammar: '#' + BlendModes; Compute: cmpValue; Animation: atDiscrete),
    { effects }
    (Group: pgEffects; Initial: '1'; Grammar: '<alpha>'; Compute: cmpOpacity; Animation: atNumber),
    (Group: pgEffects; Initial: 'none'; Grammar: '@box-shadow'; Compute: cmpValue; Animation: atShadowList),
    (Group: pgEffects; Initial: 'none'; Grammar: '@filter'; Compute: cmpValue; Animation: atByComputedValue),
    (Group: pgEffects; Initial: 'none'; Grammar: '@filter'; Compute: cmpValue; Animation: atByComputedValue),
    (Group: pgEffects; Initial: 'normal'; Grammar: BlendModes + ' | plus-darker | plus-lighter'; Compute: cmpKeyword;
      Animation: atDiscrete),
    (Group: pgEffects; Initial: 'auto'; Grammar: 'auto | isolate'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgEffects; Initial: 'none'; Grammar: '@clip-path'; Compute: cmpValue; Animation: atByComputedValue),
    (Group: pgEffects; Initial: 'auto'; Grammar: '@clip'; Compute: cmpValue; Animation: atByComputedValue),
    { masking }
    (Group: pgEffects; Initial: 'none'; Grammar: '#none | <image>'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgEffects; Initial: '0%'; Grammar: '@background-position-x'; Compute: cmpValue; Animation: atLength),
    (Group: pgEffects; Initial: '0%'; Grammar: '@background-position-y'; Compute: cmpValue; Animation: atLength),
    (Group: pgEffects; Initial: 'auto'; Grammar: '@background-size'; Compute: cmpValue; Animation: atLength),
    (Group: pgEffects; Initial: 'repeat'; Grammar: '@background-repeat'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgEffects; Initial: 'border-box'; Grammar: '#border-box | padding-box | content-box';
      Compute: cmpValue; Animation: atDiscrete),
    (Group: pgEffects; Initial: 'border-box'; Grammar: '#border-box | padding-box | content-box | no-clip';
      Compute: cmpValue; Animation: atDiscrete),
    (Group: pgEffects; Initial: 'match-source'; Grammar: '#alpha | luminance | match-source'; Compute: cmpValue;
      Animation: atDiscrete),
    { text decoration }
    (Group: pgText; Initial: 'none'; Grammar: 'none | {underline overline line-through blink spelling-error ' +
      'grammar-error}'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgText; Initial: 'solid'; Grammar: 'solid | double | dotted | dashed | wavy'; Compute: cmpKeyword;
      Animation: atDiscrete),
    (Group: pgText; Initial: 'currentcolor'; Grammar: '<color>'; Compute: cmpColor; Animation: atColor),
    (Group: pgText; Initial: 'auto'; Grammar: 'auto | from-font | <length-percentage>'; Compute: cmpLength;
      Animation: atLength),
    (Group: pgText; Initial: 'auto'; Grammar: 'auto | <length-percentage>'; Compute: cmpLength; Animation: atLength),
    (Group: pgText; Initial: 'clip'; Grammar: '@text-overflow'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgText; Initial: 'normal'; Grammar: 'normal | embed | isolate | bidi-override | isolate-override | ' +
      'plaintext'; Compute: cmpKeyword; Animation: atNone),
    { generated content }
    (Group: pgContent; Initial: 'normal'; Grammar: '@content'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgContent; Initial: 'none'; Grammar: '@counter-reset'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgContent; Initial: 'none'; Grammar: '@counter-increment'; Compute: cmpValue; Animation: atDiscrete),
    (Group: pgContent; Initial: 'none'; Grammar: '@counter-set'; Compute: cmpValue; Animation: atDiscrete),
    { table }
    (Group: pgTable; Initial: 'auto'; Grammar: 'auto | fixed'; Compute: cmpKeyword; Animation: atDiscrete),
    { columns }
    (Group: pgColumn; Initial: 'auto'; Grammar: 'auto | <integer1>'; Compute: cmpInteger; Animation: atInteger),
    (Group: pgColumn; Initial: 'auto'; Grammar: 'auto | <length+>'; Compute: cmpLength; Animation: atLength),
    (Group: pgColumn; Initial: 'medium'; Grammar: '<line-width>'; Compute: cmpLineWidth; Animation: atLength),
    (Group: pgColumn; Initial: 'none'; Grammar: BorderStyles; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgColumn; Initial: 'currentcolor'; Grammar: '<color>'; Compute: cmpColor; Animation: atColor),
    (Group: pgColumn; Initial: 'none'; Grammar: 'none | all'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgColumn; Initial: 'balance'; Grammar: 'auto | balance'; Compute: cmpKeyword; Animation: atDiscrete),
    { user interface }
    (Group: pgUi; Initial: 'auto'; Grammar: 'auto | text | none | contain | all'; Compute: cmpKeyword;
      Animation: atDiscrete),
    (Group: pgUi; Initial: 'none'; Grammar: 'none | both | horizontal | vertical | block | inline';
      Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgUi; Initial: 'auto'; Grammar: 'auto | none | manipulation | {pan-x pan-y pinch-zoom}';
      Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgUi; Initial: 'auto'; Grammar: 'auto | thin | none'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgUi; Initial: 'auto'; Grammar: 'auto | {stable both-edges}'; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgUi; Initial: 'auto'; Grammar: '@scrollbar-color'; Compute: cmpValue; Animation: atColor),
    { transitions and animations }
    (Group: pgAnimation; Initial: 'all'; Grammar: '@transition-property'; Compute: cmpValue; Animation: atNone),
    (Group: pgAnimation; Initial: '0s'; Grammar: '#<time+>'; Compute: cmpValue; Animation: atNone),
    (Group: pgAnimation; Initial: 'ease'; Grammar: '@easing-list'; Compute: cmpValue; Animation: atNone),
    (Group: pgAnimation; Initial: '0s'; Grammar: '#<time>'; Compute: cmpValue; Animation: atNone),
    (Group: pgAnimation; Initial: 'normal'; Grammar: '#normal | allow-discrete'; Compute: cmpValue; Animation: atNone),
    (Group: pgAnimation; Initial: 'none'; Grammar: '@animation-name'; Compute: cmpValue; Animation: atNone),
    (Group: pgAnimation; Initial: 'auto'; Grammar: '#auto | <time+>'; Compute: cmpValue; Animation: atNone),
    (Group: pgAnimation; Initial: 'ease'; Grammar: '@easing-list'; Compute: cmpValue; Animation: atNone),
    (Group: pgAnimation; Initial: '0s'; Grammar: '#<time>'; Compute: cmpValue; Animation: atNone),
    (Group: pgAnimation; Initial: '1'; Grammar: '#infinite | <number+>'; Compute: cmpValue; Animation: atNone),
    (Group: pgAnimation; Initial: 'normal'; Grammar: '#normal | reverse | alternate | alternate-reverse';
      Compute: cmpValue; Animation: atNone),
    (Group: pgAnimation; Initial: 'none'; Grammar: '#none | forwards | backwards | both'; Compute: cmpValue;
      Animation: atNone),
    (Group: pgAnimation; Initial: 'running'; Grammar: '#running | paused'; Compute: cmpValue; Animation: atNone),
    (Group: pgAnimation; Initial: 'replace'; Grammar: '#replace | add | accumulate'; Compute: cmpValue;
      Animation: atNone),

    { logical longhands: the grammar of what they map to }
    (Group: pgNone; Initial: '0'; Grammar: LengthPercentageAuto; Compute: cmpLength; Animation: atLength),
    (Group: pgNone; Initial: '0'; Grammar: LengthPercentageAuto; Compute: cmpLength; Animation: atLength),
    (Group: pgNone; Initial: '0'; Grammar: LengthPercentageAuto; Compute: cmpLength; Animation: atLength),
    (Group: pgNone; Initial: '0'; Grammar: LengthPercentageAuto; Compute: cmpLength; Animation: atLength),
    (Group: pgNone; Initial: '0'; Grammar: '<length-percentage+>'; Compute: cmpLength; Animation: atLength),
    (Group: pgNone; Initial: '0'; Grammar: '<length-percentage+>'; Compute: cmpLength; Animation: atLength),
    (Group: pgNone; Initial: '0'; Grammar: '<length-percentage+>'; Compute: cmpLength; Animation: atLength),
    (Group: pgNone; Initial: '0'; Grammar: '<length-percentage+>'; Compute: cmpLength; Animation: atLength),
    (Group: pgNone; Initial: 'auto'; Grammar: LengthPercentageAuto; Compute: cmpLength; Animation: atLength),
    (Group: pgNone; Initial: 'auto'; Grammar: LengthPercentageAuto; Compute: cmpLength; Animation: atLength),
    (Group: pgNone; Initial: 'auto'; Grammar: LengthPercentageAuto; Compute: cmpLength; Animation: atLength),
    (Group: pgNone; Initial: 'auto'; Grammar: LengthPercentageAuto; Compute: cmpLength; Animation: atLength),
    (Group: pgNone; Initial: 'medium'; Grammar: '<line-width>'; Compute: cmpLineWidth; Animation: atLength),
    (Group: pgNone; Initial: 'medium'; Grammar: '<line-width>'; Compute: cmpLineWidth; Animation: atLength),
    (Group: pgNone; Initial: 'medium'; Grammar: '<line-width>'; Compute: cmpLineWidth; Animation: atLength),
    (Group: pgNone; Initial: 'medium'; Grammar: '<line-width>'; Compute: cmpLineWidth; Animation: atLength),
    (Group: pgNone; Initial: 'none'; Grammar: BorderStyles; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgNone; Initial: 'none'; Grammar: BorderStyles; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgNone; Initial: 'none'; Grammar: BorderStyles; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgNone; Initial: 'none'; Grammar: BorderStyles; Compute: cmpKeyword; Animation: atDiscrete),
    (Group: pgNone; Initial: 'currentcolor'; Grammar: '<color>'; Compute: cmpColor; Animation: atColor),
    (Group: pgNone; Initial: 'currentcolor'; Grammar: '<color>'; Compute: cmpColor; Animation: atColor),
    (Group: pgNone; Initial: 'currentcolor'; Grammar: '<color>'; Compute: cmpColor; Animation: atColor),
    (Group: pgNone; Initial: 'currentcolor'; Grammar: '<color>'; Compute: cmpColor; Animation: atColor),
    (Group: pgNone; Initial: 'auto'; Grammar: SizeGrammar; Compute: cmpLength; Animation: atLength),
    (Group: pgNone; Initial: 'auto'; Grammar: SizeGrammar; Compute: cmpLength; Animation: atLength),
    (Group: pgNone; Initial: 'auto'; Grammar: SizeGrammar; Compute: cmpLength; Animation: atLength),
    (Group: pgNone; Initial: 'auto'; Grammar: SizeGrammar; Compute: cmpLength; Animation: atLength),
    (Group: pgNone; Initial: 'none'; Grammar: '@max-size'; Compute: cmpLength; Animation: atLength),
    (Group: pgNone; Initial: 'none'; Grammar: '@max-size'; Compute: cmpLength; Animation: atLength),
    (Group: pgNone; Initial: '0'; Grammar: '@radius-corner'; Compute: cmpValue; Animation: atLength),
    (Group: pgNone; Initial: '0'; Grammar: '@radius-corner'; Compute: cmpValue; Animation: atLength),
    (Group: pgNone; Initial: '0'; Grammar: '@radius-corner'; Compute: cmpValue; Animation: atLength),
    (Group: pgNone; Initial: '0'; Grammar: '@radius-corner'; Compute: cmpValue; Animation: atLength),

    { shorthands (Css.Shorthands expands them) }
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone),
    { cpCustom }
    (Group: pgNone; Initial: ''; Grammar: ''; Compute: cmpKeyword; Animation: atNone)
  );

implementation

end.

; =============================================================================
; SNOWY THE BEAR'S ADVENTURES - CoCo 3 Platformer Framework
; Motorola 6809 Assembly Language
; Target: Tandy Color Computer 3
;
; GRAPHICS MODE: 320x192 pixels, 16 colors  (max practical for CPU-accessible VRAM)
;
; MODE SELECTION -- how 320x16col is achieved (from Sock Master's GIME reference):
;   VRES HRES=111 -> 160 bytes per row
;   VRES CRES=10  -> 16 colors, 2 pixels per byte (one nibble each)
;   160 bytes/row x 2 px/byte = 320 pixels wide OK
;   VMODE BP=1, H50=0, LPR=000 -> graphics, 60 Hz, 1 scan line per row
;
;   VRES register ($FF99) value for 320x192x16col:
;     bit7   = 0 (unused)
;     bits6-5 = LPF = 00 -> 192 scan lines
;     bits4-2 = HRES = 111 -> 160 bytes/row
;     bits1-0 = CRES = 10 -> 16 colors
;     -> 0b0_00_111_10 = $1E
;
;   VMODE register ($FF98) value:
;     bit7 BP   = 1 (graphics mode)
;     bit6      = 0 (unused)
;     bit5 BPI  = 0 (composite phase -- irrelevant for RGB monitors)
;     bit4 MOCH = 0 (not monochrome)
;     bit3 H50  = 0 (60 Hz NTSC)
;     bits2-0 LPR = 000 (1 scan line per row)
;     -> 0b10000000 = $80
;
; 225-LINE VARIANT:
;   Change VRES LPF bits to 11 -> $7E instead of $1E.
;   BUT: 160 bytes/row x 225 rows = 36,000 bytes.  This requires VID_BASE at
;   $6F80 or lower to stay within the 64K address space.  See notes at bottom.
;
; SPRITE FORMAT: 4bpp packed, 2 pixels per byte (same as 160x192x16col mode,
;   just displayed at double horizontal scale).  High nibble = left pixel,
;   low nibble = right pixel.  Pixel nibble 0 = transparent.
;
; VIDEO RAM: 160 bytes/row x 192 rows = 30,720 bytes ($7800).
;   VID_BASE = $8000.  End address = $F7FF.  Fits in one 64K CPU map OK
;   (Starting at $A000 would end at $117FF -- overflow.  $8000 is mandatory.)
;
; MEMORY MAP:
;   $0000-$00FF  Direct Page (fast game variables, DP register = $00)
;   $0100-$01FF  CoCo 3 secondary interrupt vector page
;   $2000-$5FFF  Program code + sprite frame data
;   $6000-$7FFF  Sprite tables, background save buffers  
;   $7FFE        Stack base (grows down)
;   $8000-$F7FF  Video RAM (30,720 bytes -- 320x192x16 color)
;   $FE00-$FEFF  Secondary interrupt vectors (MC3 keeps this constant)
;   $FF00-$FFFF  GIME / PIA hardware registers
;
; BUILD:   lwasm --format=decb -o snowy.bin snowy_platformer.asm
; LOAD:    LOADM"SNOWY":EXEC &H2000   (Color BASIC)
;          or burn as cartridge ROM with RESET at $FFFE
; =============================================================================


; =============================================================================
; SECTION 1: HARDWARE REGISTER EQUATES
; =============================================================================

; --- GIME registers ($FF90-$FFBF) ---
GIME_INIT0  EQU  $FF90   ; Initialization register 0
                         ;   bit7 COCO  = 0 for CoCo3 modes (1 = CoCo1/2 compat, DISABLES CoCo3 gfx!)
                         ;   bit6 MMUEN = 1 enables MMU
                         ;   bit5 IEN   = 1 enables GIME IRQ output
                         ;   bit4 FEN   = 1 enables GIME FIRQ output
                         ;   bit3 MC3   = 1 keeps $FExx RAM constant (secondary vectors)
                         ;   bit2 MC2   = SCS spare chip select
                         ;   bits1-0 MC1-MC0 = ROM map: 10 = 32K internal ROM

GIME_INIT1  EQU  $FF91   ; Initialization register 1
                         ;   bit6 = 0 (64K chips), 1 (256K chips)
                         ;   bit5 TINS = timer source (1=279ns, 0=63us)
                         ;   bit0 TR   = MMU task select (0=task0 $FFA0-7, 1=task1 $FFA8-F)

GIME_IRQENR EQU  $FF92   ; IRQ  enable: bit5=TMR bit4=HBORD bit3=VBORD bit2=EI2 bit1=EI1 bit0=EI0
GIME_FIRQEN EQU  $FF93   ; FIRQ enable: same bit layout as IRQENR
                         ;   Reading either register acknowledges and clears the interrupt source.

GIME_TMR_H  EQU  $FF94   ; Timer MSB (bits 11-8)
GIME_TMR_L  EQU  $FF95   ; Timer LSB (bits 7-0)

GIME_VMODE  EQU  $FF98   ; Video mode:  bit7=BP bit5=BPI bit4=MOCH bit3=H50 bits2-0=LPR
GIME_VRES   EQU  $FF99   ; Video res:   bits6-5=LPF bits4-2=HRES bits1-0=CRES
GIME_BORDER EQU  $FF9A   ; Border color (bits5-0, same encoding as palette)
GIME_VOFF_H EQU  $FF9D   ; Video RAM offset MSB  (physical addr = value * 8 bytes)
GIME_VOFF_L EQU  $FF9E   ; Video RAM offset LSB
GIME_HOFF   EQU  $FF9F   ; Horizontal offset: bit7=HVEN (256-byte virtual row), bits6-0=X offset

; Palette registers $FFB0-$FFBF:  one byte per color entry, format 0bXX_HR_HG_HB_LR_LG_LB
;   Each color channel R, G, B is 2 bits (0-3):
;     R = (bit5 << 1) | bit2   (bit5=high, bit2=low)
;     G = (bit4 << 1) | bit1
;     B = (bit3 << 1) | bit0
;   To encode RGB(r,g,b): byte = (r>>1)<<5 | (g>>1)<<4 | (b>>1)<<3 | (r&1)<<2 | (g&1)<<1 | (b&1)
GIME_PAL    EQU  $FFB0   ; Palette 0 at $FFB0, palette 15 at $FFBF

; --- MMU bank registers ---
MMU_TASK0   EQU  $FFA0   ; Task 0 slots $FFA0-$FFA7  (slot N maps $N*$2000 CPU space)
MMU_TASK1   EQU  $FFA8   ; Task 1 slots $FFA8-$FFAF

; --- CPU speed ---
CPU_SLOW    EQU  $FFD8   ; Any write -> 0.89 MHz
CPU_FAST    EQU  $FFD9   ; Any write -> 1.79 MHz

; --- PIA 0 ($FF00-$FF03): Keyboard ---
PIA0DA      EQU  $FF00   ; Data A: write row select, read column (active-low)
PIA0CRA     EQU  $FF01
PIA0DB      EQU  $FF02   ; Data B: column read
PIA0CRB     EQU  $FF03

; --- PIA 1 ($FF20-$FF23): Sound / DAC ---
PIA1DA      EQU  $FF20
PIA1CRA     EQU  $FF21
PIA1DB      EQU  $FF22   ; DAC bits7-2 (6-bit output)
PIA1CRB     EQU  $FF23

; --- Secondary interrupt vector page ($FE00-$FEFF) ---
; Active when INIT0 bit3 MC3 = 1  (constant $FExx RAM)
; Chain: CPU reads ROM vector -> $FExx jump -> $01xx jump -> user handler
VEC2_FIRQ   EQU  $FEF4   ; FIRQ secondary vector: contains JMP instruction to $010F
VEC2_IRQ    EQU  $FEF7   ; IRQ  secondary vector: contains JMP instruction to $010C
VEC2_RESET  EQU  $FEFD   ; RESET secondary vector


; =============================================================================
; SECTION 2: GAME CONSTANTS
; =============================================================================

; --- Video ---
VID_BASE    EQU  $8000   ; Video RAM CPU address
                         ; MUST be $8000: 30,720 bytes ends at $F7FF (fits 64K)
                         ; Starting at $A000 would end at $117FF (overflow!)

SCRNW       EQU  320     ; Screen width pixels
SCRNH       EQU  192     ; Screen height pixels (LPF=00)
SCRNBPR     EQU  160     ; Bytes per screen row: 320px / 2px-per-byte = 160

; GIME video offset = physical start address / 8.
; Physical start depends on MMU setup.  For 128K CoCo3 mapping video pages
; to CPU $8000 (MMU slots 4-7 -> physical pages $38-$3B = $70000-$77FFF):
;   VOFF = $70000 / 8 = $E000  ->  VOFF_H=$E0, VOFF_L=$00
; Adjust to match your MMU configuration.
VOFF_H_VAL  EQU  $E0
VOFF_L_VAL  EQU  $00

; GIME register values for 320x192x16 colors:
VMODE_VAL   EQU  $80     ; BP=1 (graphics), H50=0 (60Hz), LPR=000 (1 line/row)
VRES_VAL    EQU  $1E     ; LPF=00(192 lines) HRES=111(160B/row) CRES=10(16col)
;VRES_225   EQU  $7E     ; LPF=11(225 lines) -- use with VID_BASE=$6F80 or lower

; --- Sprite dimensions (16x24 pixels, 4bpp) ---
SPR_W       EQU  16      ; Width in pixels
SPR_H       EQU  24      ; Height in pixels
SPR_BYTES   EQU  SPR_W/2 ; Bytes per sprite row (2 pixels/byte) = 8
SPR_SIZE    EQU  SPR_BYTES*SPR_H  ; Total bytes per frame = 192

BG_BUF_SZ   EQU  SPR_BYTES*SPR_H  ; Background save buffer = 192 bytes

; --- Physics ---
GRAVITY     EQU  1       ; Pixels added to VY per frame
VY_MAX      EQU  8       ; Terminal velocity (falling)
JUMP_VY     EQU  -10     ; Initial jump velocity (stored as $F6, two's complement)
WALK_SPD    EQU  2       ; Horizontal pixels per frame (even, keeps X byte-aligned)

; --- Platform layout (Y pixel coords) ---
GROUND_Y    EQU  160     ; Ground floor top edge
PLAT1_Y     EQU  120     ; Tier 1
PLAT2_Y     EQU  80      ; Tier 2
PLAT3_Y     EQU  40      ; Tier 3 (top)

; --- Input bit flags ---
JOY_LEFT    EQU  $01
JOY_RIGHT   EQU  $02
JOY_JUMP    EQU  $04
JOY_DOWN    EQU  $08

; --- Player states ---
STATE_IDLE  EQU  0
STATE_WALK  EQU  1
STATE_JUMP  EQU  2
STATE_FALL  EQU  3
STATE_DEAD  EQU  4

; --- Sprite record layout (9 bytes per record) ---
SPR_REC_X   EQU  0   ; byte: X pixel position
SPR_REC_Y   EQU  1   ; byte: Y pixel position
SPR_REC_W   EQU  2   ; byte: width in pixels
SPR_REC_H   EQU  3   ; byte: height in pixels
SPR_REC_PTR EQU  4   ; word: pointer to current frame pixel data
SPR_REC_BGP EQU  6   ; word: pointer to background save buffer
SPR_REC_FLG EQU  8   ; byte: flags
SPR_REC_SZ  EQU  9   ; total bytes per record

SPR_VISIBLE EQU  $01 ; Sprite should be drawn
SPR_DIRTY   EQU  $02 ; Background has been saved; must restore before moving

NUM_SPRITES EQU  6   ; Player + up to 5 enemies/items


; =============================================================================
; SECTION 3: DIRECT PAGE VARIABLES  [$0000-$00FF]
; DP register = $00 throughout the game.
; =============================================================================

        ORG  $0000

DP_START

VSYNC_CNT   RMB  1    ; Incremented each VSync FIRQ (~60 Hz)
FRAME_LO    RMB  1    ; Frame counter low byte
FRAME_HI    RMB  1    ; Frame counter high byte

INP_CUR     RMB  1    ; Current frame input bits
INP_PREV    RMB  1    ; Previous frame input bits
INP_EDGE    RMB  1    ; Edge bits: set on first press, cleared once consumed

PLR_X       RMB  1    ; Player X pixel (0-255 range via byte)
PLR_Y       RMB  1    ; Player Y pixel
PLR_VY      RMB  1    ; Vertical velocity (signed: $F6=-10, $01=+1)
PLR_STATE   RMB  1    ; Current player state
PLR_DIR     RMB  1    ; Facing direction: 0=right, 1=left
PLR_ALIVE   RMB  1    ; 1=alive, 0=dead
PLR_LIVES   RMB  1    ; Remaining lives

SCORE_0     RMB  1    ; Score BCD digits (0=ones, 3=thousands)
SCORE_1     RMB  1
SCORE_2     RMB  1
SCORE_3     RMB  1

TMP0        RMB  1    ; Scratch temporaries (subroutine use only)
TMP1        RMB  1
TMP2        RMB  1
TMP3        RMB  1

DP_END


; =============================================================================
; SECTION 4: SPRITE TABLES & BACKGROUND BUFFERS  [$6000]
; =============================================================================

        ORG  $6000

SPR_TABLE
SPR_PLAYER  RMB  SPR_REC_SZ
SPR_ENM0    RMB  SPR_REC_SZ
SPR_ENM1    RMB  SPR_REC_SZ
SPR_ENM2    RMB  SPR_REC_SZ
SPR_ITEM0   RMB  SPR_REC_SZ
SPR_ITEM1   RMB  SPR_REC_SZ

; Background save buffers (192 bytes each)
BG_BUF0     RMB  BG_BUF_SZ
BG_BUF1     RMB  BG_BUF_SZ
BG_BUF2     RMB  BG_BUF_SZ
BG_BUF3     RMB  BG_BUF_SZ
BG_BUF4     RMB  BG_BUF_SZ
BG_BUF5     RMB  BG_BUF_SZ

; Enemy state arrays (parallel with SPR_ENM0-2)
ENM_STATE   RMB  3    ; 0=inactive, 1=patrol, 2=chase
ENM_X       RMB  3
ENM_Y       RMB  3
ENM_VX      RMB  3    ; Signed horizontal velocity
ENM_HP      RMB  3


; =============================================================================
; SECTION 5: PROGRAM CODE  [$2000]
; =============================================================================

        ORG  $2000

; =============================================================================
; RESET / ENTRY POINT
; =============================================================================
RESET
        ORCC #$50         ; Disable IRQ and FIRQ during init
        LDS  #$7FFE       ; Stack at $7FFE, grows down (below video RAM at $8000)

        ; Set Direct Page register to $00 (enables fast <var addressing)
        LDA  #$00
        TFR  A,DP
        SETDP $00

        ; Zero all Direct Page variables
        LDX  #$0000
        LDB  #(DP_END-DP_START)
ZERO_DP
        CLR  ,X+
        DECB
        BNE  ZERO_DP

        ; Fast CPU (1.79 MHz)
        STA  CPU_FAST

        JSR  MMU_INIT         ; Map video pages to $8000-$F7FF
        JSR  GIME_INIT        ; Configure 320x192x16-color graphics
        JSR  PALETTE_INIT     ; Load 16-color palette
        JSR  VSYNC_INIT       ; Install FIRQ handler via $FEF4 vector chain
        JSR  SCREEN_CLEAR     ; Fill video with sky color
        JSR  DRAW_BG_STATIC   ; Draw platforms once
        JSR  GAME_INIT        ; Initialize game objects

        ANDCC #$AF        ; Enable interrupts


; =============================================================================
; MAIN GAME LOOP  (60 Hz, one iteration per VSync)
; =============================================================================
MAIN_LOOP
        JSR  WAIT_VSYNC        ; Block until next VSync tick

        INC  <FRAME_LO
        BNE  ML_NOHIB
        INC  <FRAME_HI
ML_NOHIB

        JSR  READ_INPUT        ; Keyboard scan + edge detection
        JSR  UPDATE_PLAYER     ; Input -> physics -> position
        JSR  UPDATE_ENEMIES    ; Patrol AI
        JSR  CHECK_COLLISIONS  ; AABB player-vs-enemy

        JSR  SPRITES_ERASE     ; Restore backgrounds (must come before new positions)
        JSR  SPRITES_DRAW      ; Save backgrounds + blit sprites

        BRA  MAIN_LOOP


; =============================================================================
; MMU_INIT - Map 4 consecutive physical RAM pages to CPU $8000-$FFFF
;            so that 30,720 bytes of video RAM (320x192x16col) fits in one
;            contiguous CPU address window.
;
; 128K CoCo 3 physical layout:
;   Valid RAM pages $38-$3B  ->  physical $70000-$77FFF
;   Pages $3C-$3F are internal ROM when ROM mode is active.
;
; We map:
;   CPU $8000-$9FFF (MMU slot 4) -> physical page $38 ($70000-$71FFF)
;   CPU $A000-$BFFF (MMU slot 5) -> physical page $39 ($72000-$73FFF)
;   CPU $C000-$DFFF (MMU slot 6) -> physical page $3A ($74000-$75FFF)
;   CPU $E000-$FFFF (MMU slot 7) -> physical page $3B ($76000-$77FFF)
;
; The GIME video offset must match:  VOFF = $70000 / 8 = $E000
; (Set in GIME_INIT via VOFF_H_VAL = $E0, VOFF_L_VAL = $00)
;
; IMPORTANT: Interrupt vectors at $FFF6-$FFFE are in ROM, not affected by MMU
;            slot 7 mapping.  Hardware I/O at $FF00-$FFFF is always visible.
;            $FE00-$FEFF remains constant RAM (INIT0 MC3=1).
; =============================================================================
MMU_INIT
        ; Enable MMU (set MMUEN) before writing MMU registers.
        ; We do a minimal INIT0 write here just to enable MMU; full GIME setup
        ; follows in GIME_INIT.
        LDA  #$48          ; COCO=0, MMUEN=1, MC3=1 (constant $FExx), MC1MC0=00
        STA  GIME_INIT0

        ; Write video pages to slots 4-7 ($FFA4-$FFA7)
        LDA  #$38          ; Physical page $38 -> CPU $8000
        STA  MMU_TASK0+4
        LDA  #$39
        STA  MMU_TASK0+5
        LDA  #$3A
        STA  MMU_TASK0+6
        LDA  #$3B
        STA  MMU_TASK0+7

        ; Slots 0-3 ($0000-$7FFF): map to pages containing our code/data.
        ; BASIC's default mapping or your cartridge layout applies here.
        ; For a standalone cartridge starting from reset, set these to your
        ; code pages.  Example for code in first 32KB of physical RAM ($00000):
        ;   LDA #$00 : STA MMU_TASK0+0  ; $0000 -> phys page $00
        ;   LDA #$01 : STA MMU_TASK0+1  ; $2000 -> phys page $01
        ;   LDA #$02 : STA MMU_TASK0+2  ; $4000 -> phys page $02
        ;   LDA #$03 : STA MMU_TASK0+3  ; $6000 -> phys page $03
        ; For LOADM from BASIC: BASIC has already set up slots 0-3 correctly
        ; for the load addresses.  Leave them as-is.

        RTS


; =============================================================================
; GIME_INIT - Configure 320x192x16-color graphics mode
; =============================================================================
GIME_INIT
        ; INIT0:
        ;   bit7 COCO  = 0  <- CRITICAL: must be 0 for CoCo3 graphics
        ;   bit6 MMUEN = 1  (MMU already enabled by MMU_INIT, keep it)
        ;   bit5 IEN   = 0  (no IRQ from GIME for now)
        ;   bit4 FEN   = 1  (FIRQ from GIME enabled -- VSync uses FIRQ)
        ;   bit3 MC3   = 1  (keep $FExx RAM constant -- interrupt vector chain)
        ;   bit2 MC2   = 0
        ;   bits1-0    = 10 (32K internal ROM map)
        ;   = 0b0_1_0_1_1_0_10 = $5A
        LDA  #$5A
        STA  GIME_INIT0

        ; INIT1: 64K chips, slow timer, task 0 MMU
        CLR  GIME_INIT1

        ; Video RAM physical start address (must match MMU slot 4 physical page):
        ;   VOFF = physical_start / 8  ->  $70000 / 8 = $E000
        LDA  #VOFF_H_VAL   ; $E0
        STA  GIME_VOFF_H
        LDA  #VOFF_L_VAL   ; $00
        STA  GIME_VOFF_L

        ; Video mode: graphics, 60 Hz, 1 scan line per row
        LDA  #VMODE_VAL    ; $80
        STA  GIME_VMODE

        ; Video resolution: 192 lines, 160 bytes/row, 16 colors
        LDA  #VRES_VAL     ; $1E
        STA  GIME_VRES

        ; Black border
        CLR  GIME_BORDER

        ; No horizontal offset / scroll
        CLR  GIME_HOFF

        RTS


; =============================================================================
; PALETTE_INIT - Load 16-color palette into GIME registers $FFB0-$FFBF
;
; Palette byte format: 0bXX_HR_HG_HB_LR_LG_LB
;   R = (bit5<<1)|bit2,  G = (bit4<<1)|bit1,  B = (bit3<<1)|bit0
;   Each channel: 0=off, 1=dim, 2=mid, 3=full
;
; Encoding shorthand used below (r,g,b each 0-3):
;   $00 = r=0,g=0,b=0  (black)
;   $3F = r=3,g=3,b=3  (white)
;   $24 = r=3,g=0,b=0  (full red)
;   $12 = r=0,g=3,b=0  (full green)
;   $09 = r=0,g=0,b=3  (full blue)
;   $36 = r=3,g=3,b=0  (yellow)
;   $2D = r=3,g=0,b=2  (magenta-ish)
;   $1B = r=0,g=3,b=3  (cyan)
; =============================================================================
PALETTE_INIT
        LDX  #PALETTE_DATA
        LDY  #GIME_PAL
        LDB  #16
PAL_LOOP
        LDA  ,X+
        STA  ,Y+
        DECB
        BNE  PAL_LOOP
        RTS

PALETTE_DATA
;         Encoding       r  g  b   Role
        FCB  $00    ;  0: 0,0,0 -- Transparent / solid black
        FCB  $0A    ;  1: 0,1,2 -- Mid-sky blue   (background sky)
        FCB  $1D    ;  2: 1,2,3 -- Bright sky blue (sky highlight)
        FCB  $3F    ;  3: 3,3,3 -- Snow white      (Snowy body, snow)
        FCB  $38    ;  4: 2,2,2 -- Light grey      (shadow on Snowy)
        FCB  $07    ;  5: 1,1,1 -- Dark grey       (outlines, eyes)
        FCB  $00    ;  6: 0,0,0 -- Black           (solid black, pupils)
        FCB  $12    ;  7: 0,3,0 -- Bright green    (grass)
        FCB  $10    ;  8: 0,2,0 -- Dark green      (grass shadow)
        FCB  $22    ;  9: 2,1,0 -- Brown           (platform wood/earth)
        FCB  $35    ; 10: 3,2,1 -- Light brown     (platform highlight)
        FCB  $24    ; 11: 3,0,0 -- Red             (enemies, danger)
        FCB  $36    ; 12: 3,3,0 -- Yellow          (collectible stars)
        FCB  $34    ; 13: 3,2,0 -- Orange          (collectible coins)
        FCB  $1B    ; 14: 0,3,3 -- Cyan            (ice platforms, water)
        FCB  $2D    ; 15: 3,0,2 -- Magenta         (bonus items)


; =============================================================================
; VSYNC_INIT - Install FIRQ handler via the CoCo 3 secondary vector chain
;
; The chain (from Sock Master's reference):
;   CPU reads ROM vector $FFF6 -> contains $FEF4
;   $FEF4 (constant RAM, MC3=1) -> JMP to $010F
;   $010F -> our handler (we install JMP here OR patch $FEF4 directly)
;
; We patch $FEF4 directly with a JMP extended instruction to our handler.
; This takes over the FIRQ chain completely, bypassing $010F.
;
; Also enable VBORD FIRQ in $FF93 so GIME generates FIRQ on vertical border.
; =============================================================================
VSYNC_INIT
        ; Patch $FEF4: write  JMP $7E  +  address of VSYNC_HANDLER
        LDA  #$7E              ; 6809 JMP extended opcode
        STA  VEC2_FIRQ         ; $FEF4 <- $7E
        LDD  #VSYNC_HANDLER
        STD  VEC2_FIRQ+1       ; $FEF5-$FEF6 <- address

        ; Enable GIME FIRQ on vertical border (FIRQEN bit3 VBORD = 1)
        LDA  #$08
        STA  GIME_FIRQEN

        RTS

; FIRQ handler -- called ~60 times per second on vertical border
VSYNC_HANDLER
        ; Reading FIRQEN acknowledges and clears the interrupt source
        LDA  GIME_FIRQEN
        INC  <VSYNC_CNT    ; Signal "new frame" to WAIT_VSYNC
        RTI


; =============================================================================
; WAIT_VSYNC - Spin until VSYNC_CNT increments (next frame boundary)
; =============================================================================
WAIT_VSYNC
        LDA  <VSYNC_CNT
WVS_LOOP
        CMPA <VSYNC_CNT
        BEQ  WVS_LOOP
        RTS


; =============================================================================
; READ_INPUT - Scan keyboard, latch state, compute edge-triggered bits
;
; CoCo 3 keyboard matrix (active-low):
;   Write ~(1 << row) to PIA0DA ($FF00) to select a row.
;   Read columns from PIA0DB ($FF02): bit=0 means key IS pressed.
;
; Key assignments:
;   LEFT  arrow: row $FD (bit1=0), column bit $20
;   RIGHT arrow: row $FD,          column bit $10
;   SPACE/JUMP:  row $7F (bit7=0), column bit $40
; =============================================================================
READ_INPUT
        LDA  <INP_CUR
        STA  <INP_PREV
        CLR  <TMP0

        ; Scan row $FD for LEFT and RIGHT arrows
        LDA  #$FD
        STA  PIA0DA
        LDA  PIA0DB

        BITA #$20
        BNE  RI_NO_L
        LDA  <TMP0
        ORA  #JOY_LEFT
        STA  <TMP0
RI_NO_L
        LDA  PIA0DB         ; Re-read same row
        BITA #$10
        BNE  RI_NO_R
        LDA  <TMP0
        ORA  #JOY_RIGHT
        STA  <TMP0
RI_NO_R

        ; Scan row $7F for SPACE (jump)
        LDA  #$7F
        STA  PIA0DA
        LDA  PIA0DB
        BITA #$40
        BNE  RI_NO_J
        LDA  <TMP0
        ORA  #JOY_JUMP
        STA  <TMP0
RI_NO_J

        LDA  <TMP0
        STA  <INP_CUR

        ; Edge bits = bits pressed this frame that were NOT pressed last frame
        LDA  <INP_PREV
        COMA               ; Invert: 1 = was NOT held
        ANDA <INP_CUR      ; AND with current: 1 = just pressed
        STA  <INP_EDGE
        RTS


; =============================================================================
; GAME_INIT - Initialize all game object state
; =============================================================================
GAME_INIT
        ; --- Player ---
        LDX  #SPR_PLAYER
        LDA  #152              ; Start X: near center of 320px screen
        STA  SPR_REC_X,X
        STA  <PLR_X
        LDA  #(GROUND_Y-SPR_H) ; Standing on ground
        STA  SPR_REC_Y,X
        STA  <PLR_Y
        LDA  #SPR_W
        STA  SPR_REC_W,X
        LDA  #SPR_H
        STA  SPR_REC_H,X
        LDD  #SPR_SNOWY_IDLE
        STD  SPR_REC_PTR,X
        LDD  #BG_BUF0
        STD  SPR_REC_BGP,X
        LDA  #SPR_VISIBLE
        STA  SPR_REC_FLG,X

        CLR  <PLR_VY
        CLR  <PLR_DIR
        LDA  #STATE_IDLE
        STA  <PLR_STATE
        LDA  #1
        STA  <PLR_ALIVE
        LDA  #3
        STA  <PLR_LIVES

        ; --- Enemy 0 (patrolling tier 1 left platform) ---
        LDX  #SPR_ENM0
        LDA  #30
        STA  SPR_REC_X,X
        LDA  #(PLAT1_Y-SPR_H)
        STA  SPR_REC_Y,X
        LDA  #SPR_W
        STA  SPR_REC_W,X
        LDA  #SPR_H
        STA  SPR_REC_H,X
        LDD  #SPR_ENEMY0_WALK1
        STD  SPR_REC_PTR,X
        LDD  #BG_BUF1
        STD  SPR_REC_BGP,X
        LDA  #SPR_VISIBLE
        STA  SPR_REC_FLG,X

        ; Enemy velocities
        LDA  #1
        STA  ENM_VX        ; Enemy 0: starts moving right

        RTS


; =============================================================================
; UPDATE_PLAYER - Process input, apply physics, update state and sprite record
; =============================================================================
UPDATE_PLAYER
        TST  <PLR_ALIVE
        LBEQ UP_EXIT

        ; --- Horizontal: LEFT ---
        LDA  <INP_CUR
        BITA #JOY_LEFT
        BEQ  UP_NO_L
        LDA  <PLR_X
        SUBA #WALK_SPD
        BCS  UP_CL          ; Carry set = result went below 0
        CMPA #0
        BHS  UP_SL
UP_CL   LDA  #0
UP_SL   STA  <PLR_X
        LDA  #1
        STA  <PLR_DIR
UP_NO_L

        ; --- Horizontal: RIGHT ---
        ; SCRNW-SPR_W=304=$130 overflows a byte immediate.
        ; PLR_X is a byte (0-255); cap at $F0 (240) so a 16px
        ; sprite stays fully on-screen within the byte range.
        LDA  <INP_CUR
        BITA #JOY_RIGHT
        BEQ  UP_NO_R
        LDA  <PLR_X
        ADDA #WALK_SPD
        BCS  UP_CR          ; Carry = overflowed 255, clamp
        CMPA #$F0           ; Cap at 240
        BLS  UP_SR
UP_CR   LDA  #$F0           ; Clamp to 240
UP_SR   STA  <PLR_X
        CLR  <PLR_DIR
UP_NO_R

        ; --- Jump (edge-triggered: fires only on the frame the key goes down) ---
        LDA  <PLR_STATE
        CMPA #STATE_JUMP
        BEQ  UP_GRAVITY    ; Already airborne
        CMPA #STATE_FALL
        BEQ  UP_GRAVITY

        LDA  <INP_EDGE
        BITA #JOY_JUMP
        BEQ  UP_GRAVITY
        LDA  #JUMP_VY      ; $F6 (signed -10)
        STA  <PLR_VY
        LDA  #STATE_JUMP
        STA  <PLR_STATE

UP_GRAVITY
        ; VY += gravity (capped at VY_MAX)
        LDA  <PLR_VY
        ADDA #GRAVITY
        CMPA #VY_MAX
        BLS  UP_VCAP
        LDA  #VY_MAX
UP_VCAP
        STA  <PLR_VY

        ; Y += VY (signed 8-bit add)
        LDA  <PLR_Y
        ADDA <PLR_VY
        STA  <PLR_Y

        ; --- Ground / platform collision ---
        LDA  <PLR_Y
        CMPA #(GROUND_Y-SPR_H)
        BLS  UP_AIR
        ; Hit the floor
        LDA  #(GROUND_Y-SPR_H)
        STA  <PLR_Y
        CLR  <PLR_VY
        LDA  <INP_CUR
        ANDA #(JOY_LEFT|JOY_RIGHT)
        BEQ  UP_IDLE
        LDA  #STATE_WALK
        BRA  UP_ST
UP_IDLE LDA  #STATE_IDLE
UP_ST   STA  <PLR_STATE
        BRA  UP_SYNC

UP_AIR
        LDA  <PLR_VY
        BPL  UP_FALL
        LDA  #STATE_JUMP
        BRA  UP_ST2
UP_FALL LDA  #STATE_FALL
UP_ST2  STA  <PLR_STATE

UP_SYNC
        ; Write position to sprite record
        LDX  #SPR_PLAYER
        LDA  <PLR_X
        STA  SPR_REC_X,X
        LDA  <PLR_Y
        STA  SPR_REC_Y,X

        ; Choose animation frame based on state
        LDA  <PLR_STATE
        CMPA #STATE_WALK
        BNE  UP_NW
        ; Walk: toggle frame every 4 ticks
        LDA  <FRAME_LO
        LSRA
        LSRA
        ANDA #$01
        BEQ  UP_WF0
        LDD  #SPR_SNOWY_WALK1
        BRA  UP_SF
UP_WF0  LDD  #SPR_SNOWY_WALK2
        BRA  UP_SF
UP_NW   CMPA #STATE_JUMP
        BNE  UP_NJ
        LDD  #SPR_SNOWY_JUMP
        BRA  UP_SF
UP_NJ   LDD  #SPR_SNOWY_IDLE
UP_SF   STD  SPR_REC_PTR,X

UP_EXIT
        RTS


; =============================================================================
; UPDATE_ENEMIES - Simple patrol bounce AI
; =============================================================================
UPDATE_ENEMIES
        LDX  #SPR_ENM0
        LDY  #ENM_X
        LDB  #3
UE_LOOP
        LDA  SPR_REC_FLG,X
        BITA #SPR_VISIBLE
        BEQ  UE_NEXT

        ; Move by velocity, bounce at screen edges
        LDA  ,Y            ; enemy X
        ADDA ENM_VX-ENM_X,Y
        BCS  UE_BNC        ; Carry = below 0
        CMPA #$F0           ; right cap = 240 (304=$130 overflows byte)
        BLS  UE_OK
UE_BNC  LDA  ENM_VX-ENM_X,Y
        NEGA               ; Reverse direction
        STA  ENM_VX-ENM_X,Y
        LDA  ,Y
        ADDA ENM_VX-ENM_X,Y
UE_OK   STA  ,Y
        STA  SPR_REC_X,X

        ; Animate: toggle frames every 4 ticks
        LDA  <FRAME_LO
        LSRA
        LSRA
        ANDA #$01
        BEQ  UE_F0
        LDD  #SPR_ENEMY0_WALK2
        BRA  UE_SF
UE_F0   LDD  #SPR_ENEMY0_WALK1
UE_SF   STD  SPR_REC_PTR,X

UE_NEXT
        LEAX SPR_REC_SZ,X
        LEAY 1,Y
        DECB
        BNE  UE_LOOP
        RTS


; =============================================================================
; CHECK_COLLISIONS - AABB test: player rectangle vs each enemy rectangle
; =============================================================================
CHECK_COLLISIONS
        TST  <PLR_ALIVE
        BEQ  CC_DONE

        LDX  #SPR_ENM0
        LDB  #3
CC_EACH
        LDA  SPR_REC_FLG,X
        BITA #SPR_VISIBLE
        BEQ  CC_NEXT

        ; Horizontal: enemy_right > player_left  AND  player_right > enemy_left
        LDA  SPR_REC_X,X
        ADDA #SPR_W        ; enemy_right
        CMPA <PLR_X        ; enemy_right > player_left?
        BLS  CC_NEXT

        LDA  <PLR_X
        ADDA #SPR_W        ; player_right
        CMPA SPR_REC_X,X   ; player_right > enemy_left?
        BLS  CC_NEXT

        ; Vertical: enemy_bottom > player_top  AND  player_bottom > enemy_top
        LDA  SPR_REC_Y,X
        ADDA #SPR_H
        CMPA <PLR_Y
        BLS  CC_NEXT

        LDA  <PLR_Y
        ADDA #SPR_H
        CMPA SPR_REC_Y,X
        BLS  CC_NEXT

        ; Collision!
        JSR  PLAYER_DIE

CC_NEXT
        LEAX SPR_REC_SZ,X
        DECB
        BNE  CC_EACH
CC_DONE
        RTS

PLAYER_DIE
        DEC  <PLR_LIVES
        CLR  <PLR_ALIVE
        RTS


; =============================================================================
; SPRITES_ERASE - Restore saved background under all dirty sprites
; Call this BEFORE updating positions, so backgrounds are restored at old coords.
; =============================================================================
SPRITES_ERASE
        LDX  #SPR_TABLE
        LDB  #NUM_SPRITES
SERS_L
        LDA  SPR_REC_FLG,X
        BITA #SPR_DIRTY
        BEQ  SERS_N
        JSR  BG_RESTORE
        LDA  SPR_REC_FLG,X
        ANDA #$FF^SPR_DIRTY  ; clear SPR_DIRTY bit (~SPR_DIRTY -- LWASM complement form)
        STA  SPR_REC_FLG,X
SERS_N  LEAX SPR_REC_SZ,X
        DECB
        BNE  SERS_L
        RTS


; =============================================================================
; SPRITES_DRAW - Save background and blit all visible sprites
; =============================================================================
SPRITES_DRAW
        LDX  #SPR_TABLE
        LDB  #NUM_SPRITES
SDRW_L
        LDA  SPR_REC_FLG,X
        BITA #SPR_VISIBLE
        BEQ  SDRW_N
        PSHS B
        JSR  BG_SAVE
        JSR  SPR_BLIT
        LDA  SPR_REC_FLG,X
        ORA  #SPR_DIRTY
        STA  SPR_REC_FLG,X
        PULS B
SDRW_N  LEAX SPR_REC_SZ,X
        DECB
        BNE  SDRW_L
        RTS


; =============================================================================
; CALC_VID_ADDR - Compute video RAM byte address for sprite top-left
;
; Input:   X = sprite record pointer
; Output:  Y = video RAM byte address
;
; Formula: addr = VID_BASE + (SPR_REC_Y * SCRNBPR) + (SPR_REC_X / 2)
;
; SPR_REC_X / 2 because each byte = 2 pixels (4bpp, two nibbles).
; SPR_REC_X must be even for correct nibble alignment.
; (WALK_SPD = 2 ensures this stays even throughout gameplay.)
; =============================================================================
CALC_VID_ADDR
        ; row_start = VID_BASE + Y * 160
        LDA  SPR_REC_Y,X   ; Y pixel
        LDB  #SCRNBPR      ; 160
        MUL                ; D = Y * 160  (Y < 192, fits in 15 bits)
        ADDD #VID_BASE     ; D = absolute address of row start
        TFR  D,Y

        ; column byte offset = X / 2
        LDA  SPR_REC_X,X
        LSRA               ; A = X / 2
        LEAY A,Y           ; Y = final byte address

        RTS


; =============================================================================
; BG_SAVE - Copy screen pixels under sprite to background save buffer
; Input:  X = sprite record pointer
; =============================================================================
BG_SAVE
        PSHS A,B,X,Y,U,CC

        JSR  CALC_VID_ADDR  ; Y = video source address

        LDU  SPR_REC_BGP,X  ; U = destination buffer

        LDB  SPR_REC_H,X    ; Row loop counter
BGS_ROW
        PSHS B,Y
        LDA  SPR_REC_W,X
        LSRA                ; Bytes per row = width / 2
        TFR  A,B
BGS_BYTE
        LDA  ,Y+
        STA  ,U+
        DECB
        BNE  BGS_BYTE
        PULS Y
        LEAY SCRNBPR,Y      ; Advance by full screen row stride (160 bytes)
        PULS B
        DECB
        BNE  BGS_ROW

        PULS A,B,X,Y,U,CC
        RTS


; =============================================================================
; BG_RESTORE - Copy background save buffer back to screen
; Input:  X = sprite record pointer
; =============================================================================
BG_RESTORE
        PSHS A,B,X,Y,U,CC

        JSR  CALC_VID_ADDR
        LDU  SPR_REC_BGP,X

        LDB  SPR_REC_H,X
BGR_ROW
        PSHS B,Y
        LDA  SPR_REC_W,X
        LSRA
        TFR  A,B
BGR_BYTE
        LDA  ,U+
        STA  ,Y+
        DECB
        BNE  BGR_BYTE
        PULS Y
        LEAY SCRNBPR,Y
        PULS B
        DECB
        BNE  BGR_ROW

        PULS A,B,X,Y,U,CC
        RTS


; =============================================================================
; SPR_BLIT - Draw 4bpp sprite with per-nibble transparency
;
; Input:  X = sprite record pointer
;
; Each byte in sprite data = 2 pixels:
;   High nibble ($F0 mask) = left  pixel  -- nibble 0 = transparent
;   Low  nibble ($0F mask) = right pixel  -- nibble 0 = transparent
;
; Read-modify-write keeps adjacent pixels in the same screen byte intact.
;
; Performance: 8 bytes/row x 24 rows = 192 iterations.
;   ~30 cycles/byte x 192 = 5,760 cycles.  At 1.79 MHz ? 3.2 ms/sprite.
;   6 sprites ? 19 ms -- tight but within 16.7 ms if kept to 5 sprites, or use
;   double-buffering (see notes) to allow background erasure off-screen.
; =============================================================================
SPR_BLIT
        PSHS A,B,X,Y,U,CC

        JSR  CALC_VID_ADDR
        LDU  SPR_REC_PTR,X

        LDB  SPR_REC_H,X
SB_ROW
        PSHS B,Y
        LDA  SPR_REC_W,X
        LSRA                ; Bytes per row
        TFR  A,B
SB_BYTE
        LDA  ,U+            ; Sprite byte: LLLLRRRR (left nibble | right nibble)
        STA  <TMP0

        ; --- Left pixel (high nibble) ---
        ANDA #$F0
        BEQ  SB_L_TR        ; $0x = transparent, skip
        STA  <TMP1
        LDA  ,Y
        ANDA #$0F           ; Clear screen high nibble
        ORA  <TMP1
        STA  ,Y
SB_L_TR

        ; --- Right pixel (low nibble) ---
        LDA  <TMP0
        ANDA #$0F
        BEQ  SB_R_TR        ; $x0 = transparent, skip
        STA  <TMP1
        LDA  ,Y
        ANDA #$F0           ; Clear screen low nibble
        ORA  <TMP1
        STA  ,Y
SB_R_TR

        LEAY 1,Y            ; Advance one byte = 2 pixels
        DECB
        BNE  SB_BYTE

        PULS Y
        LEAY SCRNBPR,Y      ; Next screen row (stride = 160 bytes)
        PULS B
        DECB
        BNE  SB_ROW

        PULS A,B,X,Y,U,CC
        RTS


; =============================================================================
; SCREEN_CLEAR - Fill entire video buffer with sky color
; Byte $11 = both nibbles = palette color index 1 (mid-sky blue).
; Total bytes = SCRNBPR * SCRNH = 160 * 192 = 30,720 = $7800.
; BUG FIX: LDD #$7800 overwrote A (the fill byte) before the write loop.
; Use LDY as the counter instead; LEAY affects Z flag on 6809.
; =============================================================================
SCREEN_CLEAR
        LDX  #VID_BASE
        LDA  #$11          ; fill byte: both pixels = palette color 1
        LDY  #$7800        ; loop counter = 30,720 bytes
SC_L    STA  ,X+
        LEAY -1,Y          ; LEAY sets Z flag on 6809
        BNE  SC_L
        RTS


; =============================================================================
; DRAW_BG_STATIC - Draw background elements once at level start
; =============================================================================
DRAW_BG_STATIC
        ; Draw each platform (loop through platform table)
        LDX  #PLATFORM_TABLE
        LDB  #NUM_PLATFORMS
DBGS_L
        PSHS B
        JSR  DRAW_HBAR
        PULS B
        LEAX 4,X           ; Each record: X1_byte, X2_byte, Y, FillByte
        DECB
        BNE  DBGS_L
        RTS

; Platform table:
;   X1_byte: left edge / 2  (each unit = 2 pixels, range 0-159 covers full 320px width)
;   X2_byte: right edge / 2
;   Y:       top pixel row
;   Fill:    color byte (both nibbles = same color index)
;
; GIME color indices used:
;   $99 = both pixels color 9 (brown)
;   $AA = both pixels color 10 (light brown/highlight)
;   $77 = both pixels color 7 (bright green -- ground grass top)
NUM_PLATFORMS EQU  5
PLATFORM_TABLE
; Each record: X1_byte, X2_byte, Y_pixel, FillByte  (4 bytes)
; Y values are literals -- LWASM cannot reliably evaluate EQU symbols
; inside FCB operand lists in all configurations.
; GROUND_Y=160  PLAT1_Y=120  PLAT2_Y=80  PLAT3_Y=40
;            X1B  X2B    Y    Fill
        FCB  $00,$9F,$A0,$99  ; Ground floor (full 320px width): X1=0  X2=159 Y=160
        FCB  $05,$44,$78,$99  ; Tier-1 left:  X1=5  X2=68  Y=120
        FCB  $5C,$9B,$78,$99  ; Tier-1 right: X1=92 X2=155 Y=120
        FCB  $19,$6E,$50,$99  ; Tier-2 mid:   X1=25 X2=110 Y=80
        FCB  $37,$78,$28,$99  ; Tier-3 top:   X1=55 X2=120 Y=40


; =============================================================================
; DRAW_HBAR - Draw a solid horizontal bar 4 rows tall
; Input: X -> {X1_byte, X2_byte, Y, FillByte}  (no registers trashed by caller
;             since PSHS B is used -- X itself is saved by PSHS in loop above)
; =============================================================================
DRAW_HBAR
        PSHS A,B,X,Y

        LDA  3,X           ; FillByte (both nibbles = color index)
        STA  <TMP1

        ; Video address of (X1, Y): addr = VID_BASE + Y*SCRNBPR + X1_byte
        LDA  2,X           ; Y
        LDB  #SCRNBPR      ; 160
        MUL                ; D = Y * 160
        ADDD #VID_BASE
        TFR  D,Y

        LDA  ,X            ; X1_byte (already in byte coords = pixel/2)
        LEAY A,Y           ; Y = row start byte

        ; Width in bytes = X2_byte - X1_byte
        LDA  1,X
        SUBA ,X            ; A = width bytes
        STA  <TMP0

        LDB  #4            ; 4 rows tall
DHB_ROWS
        PSHS B,Y
        LDB  <TMP0         ; bytes per row
        LDA  <TMP1         ; fill byte
DHB_FILL
        STA  ,Y+
        DECB
        BNE  DHB_FILL
        PULS Y
        LEAY SCRNBPR,Y     ; Next row
        PULS B
        DECB
        BNE  DHB_ROWS

        PULS A,B,X,Y
        RTS


; =============================================================================
; SECTION 6: SPRITE PIXEL DATA  (4bpp, 2 pixels per byte)
; =============================================================================
; Each byte = two pixels: high nibble = left pixel, low nibble = right pixel.
; Nibble 0 = transparent.
;
; Sprite size: 16 pixels wide x 24 pixels tall = 8 bytes/row x 24 rows = 192 bytes/frame.
;
; Palette mapping used in sprite data:
;   0 = transparent
;   3 = white        (Snowy body / snow)
;   4 = light grey   (shadow detail on Snowy)
;   5 = dark grey    (outlines, limbs)
;   6 = black        (eyes, nose)
;   9 = brown        (snout, ears inner)
;  11 = red          (enemy body)
;  12 = yellow       (scarf, enemy highlights)
;
; Pixel map shorthand (one byte):
;   $33 = WW  $55 = SS  $00 = ..  $03 = .W  $30 = W.
;   $36 = WY  $63 = YW  $66 = YY  $99 = BB (brown-brown)
;   $56 = SW (grey-white)  $65 = WS (white-grey)
;   $3B = WR  $B3 = RW  $BB = RR  (R=red=palette 11)
; =============================================================================

; -----------------------------------------------------------------------
; Snowy Idle  (192 bytes)
; -----------------------------------------------------------------------
SPR_SNOWY_IDLE
        FCB  $00,$33,$33,$00,$00,$33,$33,$00  ; ..WWWW....WWWW..    head top
        FCB  $03,$33,$33,$30,$03,$33,$33,$00  ; .WWWWWW..WWWWW..    head upper (ear hints start   brown inner ears at positions 1 and 6) 
        FCB  $33,$33,$33,$30,$33,$33,$33,$00  ; WWWWWWW.WWWWWW..     slightly asymmetric ear hints
        FCB  $33,$33,$36,$60,$63,$33,$33,$00  ; WWWWW__._WWWWW..     dark eyes at positions 5-6     
        FCB  $33,$33,$36,$60,$63,$33,$33,$00  ; WWWWW__._WWWWW..     dark eye highlights at positions 5-6
        FCB  $03,$33,$99,$93,$33,$33,$30,$00  ; .WWWBBBWWWWWW...     snout starts   brown
        FCB  $03,$39,$96,$93,$99,$33,$30,$00  ; .WB_BWBWBBWWW...     nose centre = dark 6
        FCB  $03,$33,$33,$33,$33,$33,$30,$00  ; .WWWWWWWWWWWW...     chin
        FCB  $00,$33,$33,$33,$33,$33,$00,$00  ; ..WWWWWWWWWW....     neck
        FCB  $CC,$CC,$CC,$CC,$CC,$CC,$CC,$CC  ; YYYYYYYYYYYYYYYY (scarf is same in walk frames)
        FCB  $CC,$CC,$CC,$CC,$CC,$CC,$CC,$CC  ; YYYYYYYYYYYYYYYY     scarf continues
        FCB  $03,$33,$33,$33,$33,$33,$30,$00  ; .WWWWWWWWWWWW...     upper body
        FCB  $33,$33,$33,$33,$33,$33,$33,$00  ; WWWWWWWWWWWWWW..      body mid-upper
        FCB  $33,$33,$33,$33,$33,$33,$33,$00  ; WWWWWWWWWWWWWW..     body mid
        FCB  $03,$33,$33,$33,$33,$33,$30,$00  ; .WWWWWWWWWWWW...     belly
        FCB  $03,$33,$33,$33,$33,$33,$30,$00  ; .WWWWWWWWWWWW...     lower body
        FCB  $03,$30,$00,$00,$00,$03,$30,$00  ; .WW.......WWW...     hip split (two legs)
        FCB  $03,$30,$00,$00,$00,$03,$30,$00  ; .WW........WW...     
        FCB  $03,$30,$00,$00,$00,$03,$30,$00  ; .WW........WW...     legs start, close together     
        FCB  $03,$30,$00,$00,$00,$03,$30,$00  ; .WW........WW...     legs, same as above (idle stance)    
        FCB  $03,$30,$00,$00,$00,$03,$30,$00  ; .WW........WW...     legs, same as above (idle stance)     
        FCB  $03,$30,$00,$00,$00,$03,$30,$00  ; .WW........WW...     legs, same as above (idle stance)      
        FCB  $03,$33,$00,$00,$00,$33,$33,$00  ; .WWW......WWWW..     feet slightly wider
        FCB  $03,$35,$00,$00,$00,$53,$33,$00  ; .WWS......SWWW..

; -----------------------------------------------------------------------
; Snowy Walk Frame 1  --  left leg forward, right leg back
; -----------------------------------------------------------------------
SPR_SNOWY_WALK1
; Rows 0-15: identical to Idle (head + body)
        FCB  $00,$33,$33,$00,$00,$33,$33,$00  ; ..WWWW....WWWW.. 
        FCB  $03,$33,$33,$30,$03,$33,$33,$00  ; .WWWWWW..WWWWW..
        FCB  $33,$33,$33,$30,$33,$33,$33,$00  ; WWWWWWW.WWWWWW..
        FCB  $33,$33,$36,$60,$63,$33,$33,$00  ; WWWWW__._WWWWW..
        FCB  $33,$33,$36,$60,$63,$33,$33,$00  ; WWWWW__._WWWWW..
        FCB  $03,$33,$99,$93,$33,$33,$30,$00  ; .WWWBBBWWWWWW...
        FCB  $03,$39,$96,$93,$99,$33,$30,$00  ; .WB_BWBWBBWWW... 
        FCB  $03,$33,$33,$33,$33,$33,$30,$00  ; .WWWWWWWWWWWW...
        FCB  $00,$33,$33,$33,$33,$33,$00,$00  ; ..WWWWWWWWWW....
        FCB  $CC,$CC,$CC,$CC,$CC,$CC,$CC,$CC  ; YYYYYYYYYYYYYYYY (scarf is same in walk frames)
        FCB  $CC,$CC,$CC,$CC,$CC,$CC,$CC,$CC  ; YYYYYYYYYYYYYYYY
        FCB  $03,$33,$33,$33,$33,$33,$30,$00  ; .WWWWWWWWWWWW...
        FCB  $33,$33,$33,$33,$33,$33,$33,$00  ; WWWWWWWWWWWWWW..
        FCB  $33,$33,$33,$33,$33,$33,$33,$00  ; WWWWWWWWWWWWWW..
        FCB  $03,$33,$33,$33,$33,$33,$30,$00  ; .WWWWWWWWWWWW...
        FCB  $03,$33,$33,$33,$33,$33,$30,$00  ; .WWWWWWWWWWWW...
        FCB  $33,$30,$00,$00,$00,$00,$33,$00  ; WWW.......WW....   (L-leg fwd, R back)
        FCB  $33,$00,$00,$00,$00,$00,$33,$30  ; WW........WWW... 
        FCB  $33,$00,$00,$00,$00,$00,$03,$33  ; WW...........WWW   (L-leg fwd, R back)
        FCB  $33,$00,$00,$00,$00,$00,$03,$33  ; WW...........WWW
        FCB  $33,$00,$00,$00,$00,$00,$03,$33  ; WW...........WWW
        FCB  $33,$00,$00,$00,$00,$00,$33,$30  ; WW..........WWW.   (R-leg folding back
        FCB  $33,$30,$00,$00,$00,$00,$33,$00  ; WWW.........WW..   (feet)
        FCB  $35,$30,$00,$00,$00,$03,$53,$00  ; WSW........WSW..   (dark toe outline)

; -----------------------------------------------------------------------
; Snowy Walk Frame 2  --  right leg forward, left leg back (mirror of WF1)
; -----------------------------------------------------------------------
SPR_SNOWY_WALK2
; Rows 0-15: same as Walk1 head+body
        FCB  $00,$33,$33,$00,$00,$33,$33,$00  ; ..WWWW....WWWW..
        FCB  $03,$33,$33,$30,$03,$33,$33,$00  ; .WWWWWW..WWWWW..
        FCB  $33,$33,$33,$30,$33,$33,$33,$00  ; WWWWWWW.WWWWWW..
        FCB  $33,$33,$36,$60,$63,$33,$33,$00  ; WWWWW__._WWWWW..
        FCB  $33,$33,$36,$60,$63,$33,$33,$00  ; WWWWW__._WWWWW..
        FCB  $03,$33,$99,$93,$33,$33,$30,$00  ; .WWWBBBWWWWWW...
        FCB  $03,$39,$96,$93,$99,$33,$30,$00  ; .WB_BWBWBBWWW...
        FCB  $03,$33,$33,$33,$33,$33,$30,$00  ; .WWWWWWWWWWWW...
        FCB  $00,$33,$33,$33,$33,$33,$00,$00  ; ..WWWWWWWWWW....
        FCB  $CC,$CC,$CC,$CC,$CC,$CC,$CC,$CC  ; YYYYYYYYYYYYYYYY (scarf is same in walk frames)
        FCB  $CC,$CC,$CC,$CC,$CC,$CC,$CC,$CC  ; YYYYYYYYYYYYYYYY
        FCB  $03,$33,$33,$33,$33,$33,$30,$00  ; .WWWWWWWWWWWW...
        FCB  $33,$33,$33,$33,$33,$33,$33,$00  ; WWWWWWWWWWWWWW..
        FCB  $33,$33,$33,$33,$33,$33,$33,$00  ; WWWWWWWWWWWWWW..
        FCB  $03,$33,$33,$33,$33,$33,$30,$00  ; .WWWWWWWWWWWW...     
        FCB  $03,$33,$33,$33,$33,$33,$30,$00  ; .WWWWWWWWWWWW...     
        FCB  $00,$33,$00,$00,$00,$00,$33,$30  ; ..WW.......WWW..   
        FCB  $03,$33,$00,$00,$00,$00,$00,$33  ; .WWW..........WW
        FCB  $33,$33,$00,$00,$00,$00,$00,$33  ; WWWW..........WW
        FCB  $33,$33,$00,$00,$00,$00,$00,$33  ; WWWW..........WW
        FCB  $33,$33,$00,$00,$00,$00,$00,$33  ; WWWW..........WW
        FCB  $03,$33,$00,$00,$00,$00,$33,$30  ; .WWW........WWW.
        FCB  $00,$33,$00,$00,$00,$00,$33,$30  ; ..WW.......WWW..
        FCB  $00,$35,$30,$00,$00,$03,$53,$00  ; ..WSW......SW...

; -----------------------------------------------------------------------
; Snowy Jump  --  arms raised, knees tucked
; -----------------------------------------------------------------------
SPR_SNOWY_JUMP
; Rows 0-8: head
        FCB  $00,$33,$33,$00,$00,$33,$33,$00  ; ..WWWW....WWWW..
        FCB  $03,$33,$33,$30,$03,$33,$33,$00  ; .WWWWWW..WWWWW..
        FCB  $33,$33,$33,$30,$33,$33,$33,$00  ; WWWWWWW.WWWWWW..
        FCB  $33,$33,$36,$60,$63,$33,$33,$00  ; WWWWW__._WWWWW..
        FCB  $33,$33,$36,$60,$63,$33,$33,$00  ; WWWWW__._WWWWW..
        FCB  $03,$33,$99,$93,$33,$33,$30,$00  ; .WWWBBBWWWWWW...
        FCB  $03,$39,$96,$93,$99,$33,$30,$00  ; .WB_BWBWBBWWW...
        FCB  $03,$33,$33,$33,$33,$33,$30,$00  ; .WWWWWWWWWWWW...
        FCB  $00,$33,$33,$33,$33,$33,$00,$00  ; ..WWWWWWWWWW....
        FCB  $CC,$CC,$CC,$CC,$CC,$CC,$CC,$CC  ; YYYYYYYYYYYYYYYY (scarf is same in walk frames)
        FCB  $CC,$CC,$CC,$CC,$CC,$CC,$CC,$CC  ; YYYYYYYYYYYYYYYY
        FCB  $03,$33,$33,$33,$33,$33,$30,$00  ; .WWWWWWWWWWWW...     upper body
        FCB  $33,$03,$33,$33,$33,$33,$03,$33  ; WW.WWWWWWWWW.WWW     (arms start, wide)
        FCB  $33,$03,$33,$33,$33,$33,$03,$33  ; WW.WWWWWWWWW.WWW     (arms, same as above)
        FCB  $00,$33,$33,$33,$33,$33,$30,$00  ; ..WWWWWWWWWWW...     
        FCB  $00,$33,$33,$33,$33,$33,$30,$00  ; ..WWWWWWWWWWW...     
        FCB  $00,$33,$33,$33,$33,$33,$00,$00  ; ..WWWWWWWWWW....     (legs tucked, close together)
        FCB  $00,$33,$33,$33,$33,$33,$00,$00  ; ..WWWWWWWWWW....     (legs tucked, close together)
        FCB  $00,$03,$33,$33,$33,$30,$00,$00  ; ...WWWWWWWW.....     (legs tucked, slightly wider)
        FCB  $00,$03,$33,$33,$33,$30,$00,$00  ; ...WWWWWWWW.....     (legs tucked, slightly wider)
        FCB  $00,$00,$33,$33,$33,$00,$00,$00  ; ....WWWWWW......     ; Rows 20-23: feet dangling
        FCB  $00,$00,$33,$33,$33,$00,$00,$00  ; ....WWWWWW......
        FCB  $00,$03,$33,$33,$33,$30,$00,$00  ; ...WWWWWWWW.....     (feet start, close together)
        FCB  $00,$05,$33,$33,$33,$50,$00,$00  ; ...SWWWWWWS.....     (feet, slightly wider, dark toe outline)

; -----------------------------------------------------------------------
; Enemy 0 Walk Frame 1  (96+96 = 192 bytes)
; Round red creature with white eyes (color 2) and dark pupils (color 6)
; -----------------------------------------------------------------------
SPR_ENEMY0_WALK1
; Head -- round red blob
        FCB  $00,$BB,$BB,$00,$00,$BB,$BB,$00  ;  ..RRRR....RRRR..
        FCB  $0B,$BB,$BB,$B0,$0B,$BB,$BB,$00  ;  .RRRRRR..RRRRR..
        FCB  $BB,$BB,$BB,$BB,$BB,$BB,$BB,$00  ;  RRRRRRRRRRRRRR..
        FCB  $BB,$B3,$36,$BB,$BB,$33,$BB,$00  ;  RRRWW_RRRRWWRR..     (eye highlights: 3=white, 6=dark pupil)
        FCB  $BB,$36,$66,$BB,$BB,$66,$BB,$00  ;  RRW___RRRR__RR..     (eye highlights: 3=white, 6=dark pupil)
        FCB  $BB,$BB,$BB,$BB,$BB,$BB,$BB,$00  ;  RRRRRRRRRRRRRR..
        FCB  $BB,$BB,$BB,$BB,$BB,$BB,$BB,$00  ;  RRRRRRRRRRRRRR..
        FCB  $BB,$BB,$BB,$BB,$BB,$BB,$BB,$00  ;  RRRRRRRRRRRRRR..
        FCB  $0B,$BB,$BB,$B0,$0B,$BB,$BB,$00  ;  .RRRRRR..RRRRR..
        FCB  $00,$BB,$BB,$00,$00,$BB,$BB,$00  ;  ..RRRR....RRRR..
        FCB  $00,$0B,$BB,$00,$00,$BB,$B0,$00  ;  ..RRR.....RRR...     (start of neck)
        FCB  $00,$00,$BB,$B0,$0B,$BB,$00,$00  ; ....RRR..RRR....     (neck/body transition)
        FCB  $00,$00,$0B,$BB,$BB,$B0,$00,$00  ; .....RRRRRR.....
        FCB  $00,$00,$00,$BB,$BB,$00,$00,$00  ; ......RRRR......
        FCB  $00,$00,$00,$00,$00,$00,$00,$00  ; ................
        FCB  $00,$00,$00,$00,$00,$00,$00,$00  ; ................
        FCB  $0B,$B0,$00,$00,$00,$0B,$B0,$00  ; .RR........RR...  Legs walk 1: left fwd, right back
        FCB  $0B,$B0,$00,$00,$00,$00,$BB,$00  ; .RR.........RR..
        FCB  $BB,$00,$00,$00,$00,$00,$BB,$00  ; RR..........RR..
        FCB  $BB,$00,$00,$00,$00,$00,$0B,$B0  ; RR...........RR.
        FCB  $BB,$00,$00,$00,$00,$00,$0B,$B0  ; RR...........RR.
        FCB  $BB,$00,$00,$00,$00,$0B,$B0,$00  ; RR.........RR...
        FCB  $BB,$B0,$00,$00,$0B,$BB,$00,$00  ; RRR......RRR....     
        FCB  $BB,$B6,$00,$00,$6B,$BB,$00,$00  ; RRR_...._RRR....

; -----------------------------------------------------------------------
; Enemy 0 Walk Frame 2  --  legs mirrored
; -----------------------------------------------------------------------
SPR_ENEMY0_WALK2
; Head identical to frame 1
        FCB  $00,$BB,$BB,$00,$00,$BB,$BB,$00  ;  ..RRRR....RRRR..
        FCB  $0B,$BB,$BB,$B0,$0B,$BB,$BB,$00  ;  .RRRRRR..RRRRR..
        FCB  $BB,$BB,$BB,$BB,$BB,$BB,$BB,$00  ;  RRRRRRRRRRRRRR..
        FCB  $BB,$B3,$36,$BB,$BB,$33,$BB,$00  ;  RRRWW_RRRRWWRR..     (eye highlights: 3=white, 6=dark pupil)
        FCB  $BB,$36,$66,$BB,$BB,$66,$BB,$00  ;  RRW___RRRR__RR..     (eye highlights: 3=white, 6=dark pupil)
        FCB  $BB,$BB,$BB,$BB,$BB,$BB,$BB,$00  ;  RRRRRRRRRRRRRR..
        FCB  $BB,$BB,$BB,$BB,$BB,$BB,$BB,$00  ;  RRRRRRRRRRRRRR..
        FCB  $BB,$BB,$BB,$BB,$BB,$BB,$BB,$00  ;  RRRRRRRRRRRRRR..
        FCB  $0B,$BB,$BB,$B0,$0B,$BB,$BB,$00  ;  .RRRRRR..RRRRR..
        FCB  $00,$BB,$BB,$00,$00,$BB,$BB,$00  ;  ..RRRR....RRRR..
        FCB  $00,$0B,$BB,$00,$00,$BB,$B0,$00  ;  ..RRR.....RRR...     (start of neck)
        FCB  $00,$00,$BB,$B0,$0B,$BB,$00,$00  ; ....RRR..RRR....     (neck/body transition)
        FCB  $00,$00,$0B,$BB,$BB,$B0,$00,$00  ; .....RRRRRR.....     (neck/body transition)
        FCB  $00,$00,$00,$BB,$BB,$00,$00,$00  ; ......RRRR......     (body)
        FCB  $00,$00,$00,$00,$00,$00,$00,$00  ; ................
        FCB  $00,$00,$00,$00,$00,$00,$00,$00  ; ................
; Legs mirrored: right fwd, left back
        FCB  $00,$BB,$00,$00,$00,$0B,$B0,$00  ; ..RR........RR...
        FCB  $00,$BB,$00,$00,$00,$0B,$B0,$00  ; ..RR........RR...
        FCB  $00,$BB,$00,$00,$00,$00,$BB,$00  ; ..RR........RR..
        FCB  $0B,$B0,$00,$00,$00,$00,$BB,$00  ; .RR.........RR..
        FCB  $0B,$B0,$00,$00,$00,$00,$BB,$00  ; .RR.........RR..
        FCB  $00,$BB,$00,$00,$00,$0B,$B0,$00  ; ..RR........RR..
        FCB  $00,$BB,$B0,$00,$0B,$BB,$00,$00  ; ..RRR....RRR....
        FCB  $00,$BB,$B6,$00,$6B,$BB,$00,$00  ; ..RRR_.._RRR....


; =============================================================================
; SECTION 7: ROM VECTORS (for standalone cartridge)
; Comment out when loading with LOADM from Color BASIC.
; =============================================================================

        ORG  $FFFE
        FDB  RESET           ; RESET vector

        END  RESET


; =============================================================================
; DEVELOPER NOTES -- 320x192 x 16 colors on CoCo 3
; =============================================================================
;
; CORRECT GIME REGISTER VALUES (verified from Sock Master's reference):
;
;   VMODE ($FF98) = $80
;     bit7 BP   = 1  -> graphics mode
;     bit5 BPI  = 0  -> (composite phase invert, irrelevant for RGB monitors)
;     bit3 H50  = 0  -> 60 Hz (set to 1 for 50 Hz / PAL)
;     bits2-0 LPR = 000 -> one scan line per row
;
;   VRES ($FF99) = $1E  (for 192 lines)
;     bits6-5 LPF = 00  -> 192 scan lines
;     bits4-2 HRES = 111 -> 160 bytes per row
;     bits1-0 CRES = 10  -> 16 colors (4bpp, 2 pixels per byte)
;
;   VRES ($FF99) = $7E  (for 225 lines)
;     bits6-5 LPF = 11  -> 225 scan lines
;     Note: 160 x 225 = 36,000 bytes.  VID_BASE must be ? $7000 for this to
;     fit in a single 64K address window ($7000 + $8CA0 = $FCA0 ? $FFFF).
;     Adjust VOFF_H/L and MMU slot mapping accordingly.
;
;   INIT0 ($FF90) -- CRITICAL:
;     bit7 COCO = 0  -- MUST be 0 for CoCo3 graphics.  Setting COCO=1 locks
;     the chip into CoCo 1/2 compatibility mode and disables all CoCo3 modes.
;     RSDOS sets INIT0=$44 for CoCo3 graphics, $C4 for CoCo1/2 modes.
;
; WHY VID_BASE = $8000 (not $A000):
;   160 bytes/row x 192 rows = 30,720 bytes.
;   $A000 + 30,720 = $117FF -- overflows 16-bit CPU address space.
;   $8000 + 30,720 = $F7FF -- fits within 64K. OK
;   Video occupies $8000-$F7FF, leaving $F800-$FDFF for stack/misc.
;
; PALETTE FORMAT:
;   Each palette byte: bits5-0 = HR HG HB LR LG LB
;   R = (bit5<<1)|bit2,  G = (bit4<<1)|bit1,  B = (bit3<<1)|bit0
;   Examples:  White=$3F  Black=$00  Red=$24  Green=$12  Blue=$09
;              Yellow=$36  Cyan=$1B  Magenta=$2D
;
; SPRITE X ALIGNMENT:
;   With 4bpp (2 pixels/byte), each screen byte covers 2 pixels.
;   SPR_REC_X must be EVEN.  WALK_SPD=2 guarantees this.
;   For true pixel-level (odd-X) placement: maintain two shifted copies of
;   each sprite row (original and rotated right 4 bits) and select by X&1.
;   This doubles sprite memory but enables sub-byte smooth movement.
;
; FULL 320-PIXEL X RANGE FOR SPRITES:
;   SPR_REC_X is a byte covering 0-255.  Positions 256-304 need extension.
;   Options:
;   (a) Promote PLR_X to a 16-bit word (PLR_X word in DP = 2 bytes), use
;       ADDD/CMPD for movement, STD to write both bytes.
;   (b) Keep byte X + separate EXT byte: add/subtract WALK_SPD, detect carry
;       to increment/decrement EXT, clamp combined value at 304.
;
; DOUBLE BUFFERING (eliminates flicker):
;   Allocate two 30,720-byte video pages:
;     Page A at CPU $8000  ->  VOFF = $E000  (MMU slots 4-7 -> pages $38-$3B)
;     Page B at CPU $8000  ->  VOFF = $E800  (MMU slots 4-7 -> pages $3C-$3F)
;   Draw to the page currently NOT displayed, then swap GIME_VOFF_H at VSync.
;   With only 128K of RAM this is tight; a 512K upgrade (standard on CoCo3)
;   gives plenty of room.
;
; PLATFORM COLLISION (full per-platform implementation):
;   After applying VY to PLR_Y, iterate PLATFORM_TABLE.  For each platform:
;     if PLR_VY > 0                                (falling)
;     && PLR_Y+SPR_H >= PLAT_Y                    (feet at or below platform top)
;     && PLR_Y+SPR_H <= PLAT_Y + 4 + VY_MAX      (didn't tunnel through)
;     && PLR_X + SPR_W > PLAT_X1*2               (horizontal overlap -- *2 for pixel coords)
;     && PLR_X < PLAT_X2*2:
;         PLR_Y = PLAT_Y - SPR_H
;         PLR_VY = 0
;         STATE = idle or walk depending on horizontal input
;
; ASSEMBLING:
;   lwasm --format=decb --output=snowy.bin snowy_platformer.asm
;   lwasm --format=raw  --output=snowy.rom snowy_platformer.asm
;
; MAME TESTING:
;   mame coco3 -cart snowy.rom
; =============================================================================

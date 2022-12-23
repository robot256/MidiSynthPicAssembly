;**********************************************************************
;   This file is a basic code template for assembly code generation   *
;   on the PIC12F629. This file contains the basic code               *
;   building blocks to build upon.                                    *
;                                                                     *
;   Refer to the MPASM User's Guide for additional information on     *
;   features of the assembler (Document DS33014).                     *
;                                                                     *
;   Refer to the respective PIC data sheet for additional             *
;   information on the instruction set.                               *
;                                                                     *
;**********************************************************************
;                                                                     *
;    Filename:      xxx.asm                                           *
;    Date:                                                            *
;    File Version:                                                    *
;                                                                     *
;    Author:                                                          *
;    Company:                                                         *
;                                                                     *
;                                                                     *
;**********************************************************************
;                                                                     *
;    Files Required: P12F629.INC                                      *
;                                                                     *
;**********************************************************************
;                                                                     *
;    Notes:                                                           *
;                                                                     *
;**********************************************************************

    list      p=12f629           ; list directive to define processor
    #include <p12f629.inc>        ; processor specific variable definitions

    errorlevel  -302              ; suppress message 302 from list file

    __CONFIG   _CP_OFF & _CPD_OFF & _BODEN_ON & _MCLRE_OFF & _WDT_OFF & _PWRTE_ON & _HS_OSC

; '__CONFIG' directive is used to embed configuration word within .asm file.
; The lables following the directive are located in the respective .inc file.
; See data sheet for additional information on configuration word settings.


#define TONE_OUTPUT     GPIO,0
#define TONE_OUTPUT_MASK 0x01
#define CMP_INPUT       GPIO,1
#define TRIGGER_OUTPUT  GPIO,2
#define SERIAL_INPUT    GPIO,3


; Serial port timing constants
#define BIT125_PRELOAD  d'60'
#define BIT_PRELOAD     d'98'
#define BIT025_PRELOAD  d'220'

; Midi command definitions
#define MIDI_CHANNEL    0x00
#define MIDI_ON_CMD     0x90
#define MIDI_OFF_CMD    0x80

; Tone table parameters
#define TABLE_PSM1_START  d'48'
#define TABLE_PS0_START   d'36'
#define TABLE_PS1_START   d'24'
#define TABLE_PS2_START   d'12'
#define TABLE_PS3_START   d'0'

#define ISR_PS0_OVERHEAD  d'24'
#define ISR_PS1_OVERHEAD  d'12'
#define ISR_PS2_OVERHEAD  d'6'
#define ISR_PS3_OVERHEAD  d'3'


;***** VARIABLE DEFINITIONS
w_temp          EQU 0x20        ; variable used for context saving 
status_temp     EQU 0x21        ; variable used for context saving

uartState       EQU 0x22        ; uart receiver bit counter (0=wait for start bit, 16=wait for stop bit, 1-8=wait for bit 0-7)
uartData        EQU 0x23        ; uart receiver shift register
uartDataReady   EQU 0x24        ; Flag for uart byte ready

midiState       EQU 0x25        ; Midi packet state (0=waiting for status byte, 1=waiting for note byte, 2=waiting for velocity byte)
midiStatus      EQU 0x26        ; Midi stream current status byte
midiNoteBuf     EQU 0x27        ; Midi stream current note byte
midiVelocityBuf EQU 0x28        ; Midi stream current velocity byte
midiCmdReady    EQU 0x29        ; Code for the Midi command that is ready to be processed (1=Note ON, 2=Note OFF)

noteNumber      EQU 0x2A        ; ID of the note currently playing (255=off)

tempPreloadL    EQU 0x31
tempPreloadH    EQU 0x32
tempPrescaler   EQU 0x2F
tempDelay       EQU 0x30

tonePreloadL    EQU 0x2B        ; Value to load TMR1 with for every note half-period
tonePreloadH    EQU 0x2C
tonePrescaler   EQU 0x2D        ; Value to load TMR1 prescaler (0=1:1, 1=2:1, 2=4:1, 3=8:1)
toneDelay       EQU 0x2E        ; Add single cycle delay to note HIGH period

        
;***** MACRO DEFINITIONS
ReadToneTable  macro  __dest        ; Retrieve the WREG'th 16-bit value from the ToneTable
        movwf   FSR
        addwf   FSR,f               ; PC offset is 2*index
        call    ToneTableLookup
        movwf   __dest
        call    ToneTableLookup     ; FSR was automatically incremented, so this gets MSB
        movwf   __dest+1
    endm


;**********************************************************************
        ORG     0x000             ; processor reset vector
        goto    main              ; go to beginning of program


        ORG     0x004             ; interrupt vector location
        movwf   w_temp            ; save off current W register contents
        movf    STATUS,w          ; move status register into W register
        movwf   status_temp       ; save off contents of STATUS register


        ; Only interrupt used is TMR1
        bcf     PIR1,TMR1IF
        
        ; Toggle the frequency output
        movlw   TONE_OUTPUT_MASK
        xorwf   GPIO,f
        
        ; Reset the timer (this will apply a new tone as well)
        swapf   tonePrescaler,w     ; Shift prescaler setting into correct bits
        movwf   T1CON               ; Set prescaler and disable TMR1 for updating
        
        ; Add a delay that is 1 cycle extra if ~(TONE_OUTPUT & toneDelay)
        movf    toneDelay,w
        andwf   GPIO,w
        btfsc   STATUS,Z
        goto    shortDelay
        ; long delay
        goto    shortDelay
shortDelay:
        nop
        nop
        nop
        nop
        
        ; Load the TMR1 preload value
        movf    tonePreloadL,w
        movwf   TMR1L
        movf    tonePreloadH,w
        movwf   TMR1H
        ; Reenable TMR1
        bsf     T1CON,TMR1ON

        movf    status_temp,w     ; retrieve copy of STATUS register
        movwf   STATUS            ; restore pre-isr STATUS register contents
        swapf   w_temp,f
        swapf   w_temp,w          ; restore pre-isr W register contents
        retfie                    ; return from interrupt

;-----------------------------------
ToneTableLookup:
;{
        ; Argument: Place (noteNumber-48)*2 in FSR register
        ; Results:  FSR is incremented
        ;           WREG = 0 - (Note period in clocks)
        ;clrf    PCLATH
        movf    FSR,w
        incf    FSR,f
        addwf   PCL,f
        retlw   0xb1 ; Note  48: 6ab1 =  0 - 38223
        retlw   0x6a
        retlw   0x13 ; Note  49: 7313 =  0 - 36077
        retlw   0x73
        retlw   0xfc ; Note  50: 7afc =  0 - 34052
        retlw   0x7a
        retlw   0x73 ; Note  51: 8273 =  0 - 32141
        retlw   0x82
        retlw   0x7f ; Note  52: 897f =  0 - 30337
        retlw   0x89
        retlw   0x25 ; Note  53: 9025 =  0 - 28635
        retlw   0x90
        retlw   0x6d ; Note  54: 966d =  0 - 27027
        retlw   0x96
        retlw   0x59 ; Note  55: 9c59 =  0 - 25511
        retlw   0x9c
        retlw   0xf1 ; Note  56: a1f1 =  0 - 24079
        retlw   0xa1
        retlw   0x39 ; Note  57: a739 =  0 - 22727
        retlw   0xa7
        retlw   0x34 ; Note  58: ac34 =  0 - 21452
        retlw   0xac
        retlw   0xe8 ; Note  59: b0e8 =  0 - 20248
        retlw   0xb0
        retlw   0x59 ; Note  60: b559 =  0 - 19111
        retlw   0xb5
        retlw   0x89 ; Note  61: b989 =  0 - 18039
        retlw   0xb9
        retlw   0x7e ; Note  62: bd7e =  0 - 17026
        retlw   0xbd
        retlw   0x39 ; Note  63: c139 =  0 - 16071
        retlw   0xc1
        retlw   0xbf ; Note  64: c4bf =  0 - 15169
        retlw   0xc4
        retlw   0x13 ; Note  65: c813 =  0 - 14317
        retlw   0xc8
        retlw   0x36 ; Note  66: cb36 =  0 - 13514
        retlw   0xcb
        retlw   0x2d ; Note  67: ce2d =  0 - 12755
        retlw   0xce
        retlw   0xf9 ; Note  68: d0f9 =  0 - 12039
        retlw   0xd0
        retlw   0x9c ; Note  69: d39c =  0 - 11364
        retlw   0xd3
        retlw   0x1a ; Note  70: d61a =  0 - 10726
        retlw   0xd6
        retlw   0x74 ; Note  71: d874 =  0 - 10124
        retlw   0xd8
        retlw   0xac ; Note  72: daac =  0 -  9556
        retlw   0xda
        retlw   0xc5 ; Note  73: dcc5 =  0 -  9019
        retlw   0xdc
        retlw   0xbf ; Note  74: debf =  0 -  8513
        retlw   0xde
        retlw   0x9d ; Note  75: e09d =  0 -  8035
        retlw   0xe0
        retlw   0x60 ; Note  76: e260 =  0 -  7584
        retlw   0xe2
        retlw   0x09 ; Note  77: e409 =  0 -  7159
        retlw   0xe4
        retlw   0x9b ; Note  78: e59b =  0 -  6757
        retlw   0xe5
        retlw   0x16 ; Note  79: e716 =  0 -  6378
        retlw   0xe7
        retlw   0x7c ; Note  80: e87c =  0 -  6020
        retlw   0xe8
        retlw   0xce ; Note  81: e9ce =  0 -  5682
        retlw   0xe9
        retlw   0x0d ; Note  82: eb0d =  0 -  5363
        retlw   0xeb
        retlw   0x3a ; Note  83: ec3a =  0 -  5062
        retlw   0xec
        retlw   0x56 ; Note  84: ed56 =  0 -  4778
        retlw   0xed
        retlw   0x62 ; Note  85: ee62 =  0 -  4510
        retlw   0xee
        retlw   0x5f ; Note  86: ef5f =  0 -  4257
        retlw   0xef
        retlw   0x4e ; Note  87: f04e =  0 -  4018
        retlw   0xf0
        retlw   0x30 ; Note  88: f130 =  0 -  3792
        retlw   0xf1
        retlw   0x05 ; Note  89: f205 =  0 -  3579
        retlw   0xf2
        retlw   0xce ; Note  90: f2ce =  0 -  3378
        retlw   0xf2
        retlw   0x8b ; Note  91: f38b =  0 -  3189
        retlw   0xf3
        retlw   0x3e ; Note  92: f43e =  0 -  3010
        retlw   0xf4
        retlw   0xe7 ; Note  93: f4e7 =  0 -  2841
        retlw   0xf4
        retlw   0x87 ; Note  94: f587 =  0 -  2681
        retlw   0xf5
        retlw   0x1d ; Note  95: f61d =  0 -  2531
        retlw   0xf6
        retlw   0xab ; Note  96: f6ab =  0 -  2389
        retlw   0xf6
        retlw   0x31 ; Note  97: f731 =  0 -  2255
        retlw   0xf7
        retlw   0xb0 ; Note  98: f7b0 =  0 -  2128
        retlw   0xf7
        retlw   0x27 ; Note  99: f827 =  0 -  2009
        retlw   0xf8
        retlw   0x98 ; Note 100: f898 =  0 -  1896
        retlw   0xf8
        retlw   0x02 ; Note 101: f902 =  0 -  1790
        retlw   0xf9
        retlw   0x67 ; Note 102: f967 =  0 -  1689
        retlw   0xf9
        retlw   0xc6 ; Note 103: f9c6 =  0 -  1594
        retlw   0xf9
        retlw   0x1f ; Note 104: fa1f =  0 -  1505
        retlw   0xfa
        retlw   0x74 ; Note 105: fa74 =  0 -  1420
        retlw   0xfa
        retlw   0xc3 ; Note 106: fac3 =  0 -  1341
        retlw   0xfa
        retlw   0x0f ; Note 107: fb0f =  0 -  1265
        retlw   0xfb
        retlw   0x56 ; Note 108: fb56 =  0 -  1194
        retlw   0xfb
        retlw   0x99 ; Note 109: fb99 =  0 -  1127
        retlw   0xfb
        retlw   0xd8 ; Note 110: fbd8 =  0 -  1064
        retlw   0xfb
        retlw   0x14 ; Note 111: fc14 =  0 -  1004
        retlw   0xfc
        retlw   0x4c ; Note 112: fc4c =  0 -   948
        retlw   0xfc
        retlw   0x81 ; Note 113: fc81 =  0 -   895
        retlw   0xfc
        retlw   0xb3 ; Note 114: fcb3 =  0 -   845
        retlw   0xfc
        retlw   0xe3 ; Note 115: fce3 =  0 -   797
        retlw   0xfc
        retlw   0x10 ; Note 116: fd10 =  0 -   752
        retlw   0xfd
        retlw   0x3a ; Note 117: fd3a =  0 -   710
        retlw   0xfd
        retlw   0x62 ; Note 118: fd62 =  0 -   670
        retlw   0xfd
        retlw   0x87 ; Note 119: fd87 =  0 -   633
        retlw   0xfd
        retlw   0xab ; Note 120: fdab =  0 -   597
        retlw   0xfd
        retlw   0xcc ; Note 121: fdcc =  0 -   564
        retlw   0xfd
        retlw   0xec ; Note 122: fdec =  0 -   532
        retlw   0xfd
        retlw   0x0a ; Note 123: fe0a =  0 -   502
        retlw   0xfe
        retlw   0x26 ; Note 124: fe26 =  0 -   474
        retlw   0xfe
        retlw   0x41 ; Note 125: fe41 =  0 -   447
        retlw   0xfe
        retlw   0x5a ; Note 126: fe5a =  0 -   422
        retlw   0xfe
        retlw   0x71 ; Note 127: fe71 =  0 -   399
        retlw   0xfe
;}
;-----------------------------------

main:
; these first 4 instructions are not required if the internal oscillator is not used
        ;call    0x3FF             ; retrieve factory calibration value
        ;bsf     STATUS,RP0        ; set file register bank to 1 
        ;movwf   OSCCAL            ; update register with factory cal value 
        ;bcf     STATUS,RP0        ; set file register bank to 0


; remaining code goes here
        
;-----------------------------------
; Initialize SFRs
;{  ; TRISIO
    ; Frequency output on pin GP0
    ; Channel select divider on pin GP1 (ANALOG) (NOT CONNECTED, SET TO OUTPUT)
    ; Trigger output on pin GP2
    ; UART input on pin GP3
    ; Crystal on pins GP4 and GP5
        bsf     STATUS,RP0
        movlw   0x38
        movwf   TRISIO
    ; OPTION_REG
    ; TMR0 internal clock, no prescaler
    ; Pull-ups disabled
        movlw   0x88
        movwf   OPTION_REG
    ; TMR1 Interrupt enabled
        movlw   0x01
        movwf   PIE1
        bcf     STATUS,RP0

    ; GPIO
    ; Turn off I/O pins
        clrf    GPIO
    
    ; PCLATH: By default, all computed gotos are in page 0
        clrf    PCLATH

    ; CMCON
    ; Comparator in single-pin mode
        movlw   0x07
        movwf   CMCON

    ; T1CON
    ; Timer1 turned on, no prescaler by default
        movlw   0x01
        movwf   T1CON
    
    ; Enable peripheral interrupts, GIE off until a note is set
        movlw   0x40
        movwf   INTCON
;-----------------------------------
;}

;-----------------------------------
; Initialize Variables
;{
        movlw   0x10            ; Uart starts waiting for the idle state on the line
        movwf   uartState
        clrf    uartData
        clrf    uartDataReady
        clrf    midiState
        clrf    midiStatus
        clrf    midiNoteBuf
        clrf    midiVelocityBuf
        clrf    midiCmdReady
        
        movlw   d'69'           ; Default note to A440
        movwf   noteNumber
        goto    toneSetFrequency
;-----------------------------------
;}

;-----------------------------------
mainloop:
midiPacketDone:
toneUpdateSkip:
toneUpdateDone:


        ;bcf     INTCON,GIE
        ;movlw   4
        ;xorwf   GPIO,f
        ;goto    $-2

;     ------------------------
;         Poll Serial Input
;{
        btfss   INTCON,T0IF
        goto    uartSkip
        bcf     INTCON,T0IF

        ; Check uartState
        movf    uartState,f
        btfss   STATUS,Z
        goto    uartStopCheck
        ; uartState==0, wait for start bit
        movlw   BIT025_PRELOAD      ; if input is still high, check again in 1/4 baud
        btfsc   SERIAL_INPUT
        goto    uartTimerLoad
        ; serialIn==0, start bit has started
        clrf    uartData
        clrf    uartDataReady
        incf    uartState,f
        movlw   BIT125_PRELOAD      ; center of first data bit is 1.25 to 1.5 baud from now
        goto    uartTimerLoad

uartStopCheck:
        btfss   uartState,4
        goto    uartBitShift
        ; uartState==16, wait for stop bit to appear
        btfsc   SERIAL_INPUT
        clrf    uartState       ; stop bit HIGH detected, now safe to wait for start bit LOW
        movlw   BIT025_PRELOAD  ; check for stop or start bit again in 1/4 baud
        goto    uartTimerLoad

uartBitShift:
        ; uartState indicates waiting for a data bit
        ; shift in the data from the input pin
        bcf     STATUS,C
        btfsc   SERIAL_INPUT
        bsf     STATUS,C
        rrf     uartData,f
        movlw   BIT_PRELOAD     ; Next bit (or stop bit) is one baud away
        ; check if we have 8 bits yet
        btfsc   uartState,3
        goto    uartByteDone
        incf    uartState,f
        goto    uartTimerLoad
        
uartByteDone:
        bsf     uartDataReady,0 ; Indicate uart data is ready to be processed
        movlw   0x10
        movwf   uartState       ; Next wait for the line to go idle again
        movlw   BIT025_PRELOAD  ; check frequently for the start of the stop bit
        
uartTimerLoad:
        addwf   TMR0,F          ; Add value to TMR0 counter, so it doesn't matter how late we are
        btfsc   STATUS,C        ; If we waited too long to load the timer, this will cause an overflow,
        bsf     INTCON,T0IF     ;   so we flag that another loop should execute immediately

uartSkip:
;     ------------------------
;}
;     ------------------------
;         Midi Packet FSM
;{
        btfss   uartDataReady,0
        goto    midiPacketSkip
        bcf     uartDataReady,0
        
        ; Check if new byte is status
        btfss   uartData,7
        goto    midiDataByte
        ; This is a status byte, check if it's an allowed status
        clrf    midiState
        movf    uartData,w
        iorlw   0x10        ; don't care if command is ON or OFF
        xorlw   (MIDI_ON_CMD|MIDI_CHANNEL)  ; Just need channel and upper 3 bits of command to match
        btfss   STATUS,Z
        goto    midiPacketDone
        ; This status is allowed. Start receiving data
        clrf    midiCmdReady ; data bytes are now invalid
        bsf     midiState,0     ; next byte is note number
        movf    uartData,w
        movwf   midiStatus      ; store the status word
        goto    midiPacketDone
        
midiDataByte:
        ; Not a midi status byte
        ; See if we are expecting any data bytes
        btfss   midiState,0
        goto    midiVelocityByte
        ; This is a midi note number byte
        movf    uartData,w
        movwf   midiNoteBuf     ; store the note number in buffer
        incf    midiState,f     ; next byte is note velocity
        goto    midiPacketDone
        
midiVelocityByte:
        btfss   midiState,1
        goto    midiPacketDone  ; We are still in midiState=0, so no data should be saved
        ; This is a midi note velocity byte
        movf    uartData,w
        movwf   midiVelocityBuf ; store the note velocity in buffer
        decf    midiState,f     ; next byte is another note number, if we don't get a new status
        bsf     midiCmdReady,0   ; indicate new note/velocity can be processed
        goto    midiPacketDone
        
        ; midiPacketDone label is at mainloop
        ; If a UART byte was processed, go back and poll the uart before updating the tone
        
midiPacketSkip:
;     ------------------------
;}

;     ------------------------
;         Midi Command Exec
;{
        btfss   midiCmdReady,0
        goto    toneUpdateSkip
        bcf     midiCmdReady,0
 
        ; Process the MIDI command (ON or OFF)
        btfss   midiStatus,4
        goto    toneOffCommand
        ; We have a new tone ON command
        ; Make sure it's not actually an OFF command
        movf    midiVelocityBuf,w
        btfsc   STATUS,Z
        goto    toneOffCommand
        ; Yup, it's a new ON command
        
        ; Store the new number of the note we're supposed to play
        movf    midiNoteBuf,w
        movwf   noteNumber

toneSetFrequency:
        clrf    tempDelay           ; Initialize the delay to 0
        
        ; Compute what the prescaler setting needs to be for it
        movlw   TABLE_PSM1_START
        subwf   noteNumber,w
        btfsc   STATUS,C
        goto    toneOnPSM1
        ; noteNumber < 48, check which multiple of 12 we are inside
        movlw   TABLE_PS1_START
        subwf   noteNumber,w
        btfsc   STATUS,C
        goto    toneOnPS1or0
        ; noteNumber < 24, Prescaler is 3 or 2
        movlw   TABLE_PS2_START
        subwf   noteNumber,w
        btfsc   STATUS,C
        goto    toneOnPS2
        
        ; noteNumber < 12, Prescaler is 3
        ; Retrieve table value. WREG already contains noteNumber-12, which is negative
        ; Get entry noteNumber
        movf    noteNumber,w
        ReadToneTable  tempPreloadL
        ; Set Prescaler=3
        movlw   0x03
        movwf   tempPrescaler
        ; Preload = Table + ISR_PS3_OVERHEAD
        movlw   ISR_PS3_OVERHEAD
        goto    toneOnWriteValue

toneOnPS2:
        ; noteNumber >= 12, < 24, Prescaler is 2
        ; Retrieve table value. WREG already contains noteNumber-12, which is positive
        ; Get entry noteNumber-12
        ReadToneTable  tempPreloadL
        ; Set Prescaler=2
        movlw   0x02
        movwf   tempPrescaler
        ; Preload = Table + ISR_PS2_OVERHEAD
        movlw   ISR_PS2_OVERHEAD
        goto    toneOnWriteValue
        
toneOnPS1or0:
        ; noteNumber >= 24, < 48, Prescaler is 1 or 0 with no delay
        movlw   TABLE_PS0_START
        subwf   noteNumber,w
        btfsc   STATUS,C
        goto    toneOnPS0
        
        ; noteNumber >= 24, < 36, Prescaler is 1
        ; Retrieve table value. WREG already contains noteNumber-36, which is negative
        ; Get entry noteNumber-24
        addlw   TABLE_PS0_START-TABLE_PS1_START     ; add 12 to address before multiplying
        ReadToneTable  tempPreloadL
        ; Set Prescaler=1
        movlw   0x01
        movwf   tempPrescaler
        ; Preload = Table + ISR_PS1_OVERHEAD
        movlw   ISR_PS1_OVERHEAD
        goto    toneOnWriteValue
        
toneOnPS0:
        ; noteNumber >= 36, < 48, Prescaler is 0 with no delay
        ; Retrieve table value. WREG already contains noteNumber-36, which is positive
        ; Get entry noteNumber-36
        ReadToneTable  tempPreloadL
        ; Set Prescaler=0
        ; Preload = Table + ISR_PS0_OVERHEAD
        goto    toneOnWriteValuePS0
        
toneOnPSM1:
        ; Retrieve table value. WREG already contains noteNumber-48, which is positive
        ; Get entry noteNumber-48
        ReadToneTable  tempPreloadL
        ; Divide table value by 2 to get the half-cycle time
        bsf     STATUS,C            ; Table value is negative, extend sign
        rrf     tempPreloadH,f
        rrf     tempPreloadL,f
        rlf     tempDelay,f         ; If table value was odd, then we delay one of the half-cycles by one clock
        btfsc   tempDelay,0
        incf    tempPreloadL,f        ; If we shifted out a 1, round up toward zero
toneOnWriteValuePS0:
        ; Set Prescaler=0
        clrf    tempPrescaler       ; By definition, prescaler is 0 when divide by 2
        ; Preload = Table/2 + ISR_PS0_OVERHEAD
        movlw   ISR_PS0_OVERHEAD
        
toneOnWriteValue:
        ; Add the overhead value (in WREG) to the -Table value in tempPreload
        addwf   tempPreloadL,f
        btfsc   STATUS,C
        incf    tempPreloadH,f
        ; Disable interrupts and update the tone registers for the ISR to read
        bcf     INTCON,GIE
        movf    tempPreloadL,w
        movwf   tonePreloadL
        movf    tempPreloadH,w
        movwf   tonePreloadH
        movf    tempPrescaler,w
        movwf   tonePrescaler
        movf    tempDelay,w
        movwf   toneDelay
        bsf     INTCON,GIE
        ; Enable the trigger output
        bsf     TRIGGER_OUTPUT
        goto    toneUpdateDone
        
toneOffCommand:
        ; Only act if this command matches the current note
        movf    noteNumber,w
        xorwf   midiNoteBuf,w
        btfss   STATUS,Z
        goto    toneUpdateDone
        ; Note matches, turn it off
        movlw   0xFF
        movwf   noteNumber
        ; Leave the frequency output unchanged during the decay period
        ;;;; TEMP: Disable the tone output immediately instead of letting it decay
        bcf     INTCON,GIE
        nop
        bcf     TONE_OUTPUT     ; Disable the tone output so the speaker stays non-energized
        ; Disable the trigger output
        bcf     TRIGGER_OUTPUT
        
        goto    toneUpdateDone
        
        ; toneUpdateSkip and toneUpdateDone are both at mainloop
        ; No sense having another goto strung after it
;}
;     ------------------------

        goto    mainloop    ; this here for extra
;-----------------------------------



        END                       ; directive 'end of program'


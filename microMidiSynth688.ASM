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


; GPIO Pin Mapping
#define TONE_OUTPUT     GPIO,2
#define TONE_OUTPUT_MASK 0x04
#define CMP_INPUT       GPIO,1
#define TRIGGER_OUTPUT  GPIO,0
#define SERIAL_INPUT    GPIO,3


; Serial port timing constants
#define BIT125_PRELOAD  d'60'
#define BIT_PRELOAD     d'98'
#define BIT025_PRELOAD  d'220'

; Midi command definitions
#define MIDI_CHANNEL    0x00
#define MIDI_ON_CMD     0x90
#define MIDI_OFF_CMD    0x80
#define MIDI_BEND_CMD   0xE0

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

toneCmdReady    EQU 0x2A
tonePreloadL    EQU 0x2B        ; Value to load TMR1 with for every note half-period
tonePreloadH    EQU 0x2C
tonePrescaler   EQU 0x2D        ; Value to load TMR1 prescaler (0=1:1, 1=2:1, 2=4:1, 3=8:1)
toneDelay       EQU 0x2E        ; Add single cycle delay to note HIGH period

tempPrescaler   EQU 0x2F
tempDelay       EQU 0x30
tempPreloadL    EQU 0x31
tempPreloadH    EQU 0x32
tableAddress    EQU 0x33

noteBendValue   EQU 0x34

noteNumber      EQU 0x35        ; ID of the note currently playing (255=off)
noteStack1      EQU 0x36
noteStack2      EQU 0x37
noteStack3      EQU 0x38
noteStack4      EQU 0x39
noteStack5      EQU 0x3A
noteStack6      EQU 0x3B
noteStack7      EQU 0x3C

pitchBendCmdReady EQU   0x3D
bendAmountL     EQU 0x3E
bendAmountH     EQU 0x3F
bendTempL       EQU 0x40
bendTempH       EQU 0x41
bendTableValue  EQU 0x42

;#define TEST_NOTE_STACK


;**********************************************************************
        ORG     0x000             ; processor reset vector
        goto    main              ; go to beginning of program

        ; Version number: 2.3
        retlw   0x02
        retlw   0x03

;-----------------------------------
; INTERRUPT SERVICE ROUTINE
        ORG     0x004             ; interrupt vector location
;{
        movwf   w_temp            ; save off current W register contents
        movf    STATUS,w          ; move status register into W register
        movwf   status_temp       ; save off contents of STATUS register

        btfsc   INTCON,PEIE
        btfss   PIR1,TMR1IF
        goto    isrCheckUart

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
        nop
        nop
shortDelay:
        nop
        
        ; Load the TMR1 preload value
        movf    tonePreloadL,w
        movwf   TMR1L
        movf    tonePreloadH,w
        movwf   TMR1H
        ; Reenable TMR1
        bsf     T1CON,TMR1ON

isrCheckUart:
        btfss   INTCON,T0IF
        goto    isrDone
; Run the UART code

;     ------------------------
;         Poll Serial Input

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
;     ------------------------


isrDone:
        movf    status_temp,w     ; retrieve copy of STATUS register
        movwf   STATUS            ; restore pre-isr STATUS register contents
        swapf   w_temp,f
        swapf   w_temp,w          ; restore pre-isr W register contents
        retfie                    ; return from interrupt
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
;{  
    ; Select BANK1 for certain special function registers
        bsf     STATUS,RP0
    ; TRISIO
    ; Frequency output on pin GP0
    ; Channel select divider on pin GP1 (ANALOG) (NOT CONNECTED, SET TO OUTPUT)
    ; Trigger output on pin GP2
    ; UART input on pin GP3
    ; Crystal on pins GP4 and GP5
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

    ; Select BANK0 for the remainder of the program
        bcf     STATUS,RP0

    ; TMR0
    ; Reset it so we wait a while before the first UART polling
        clrf    TMR0

    ; GPIO
    ; Turn off I/O pins
        clrf    GPIO
    
    ; PCLATH: By default, all computed gotos are in page 3
        movlw   0x02
        movwf   PCLATH

    ; CMCON
    ; Comparator in single-pin mode
        movlw   0x07
        movwf   CMCON

    ; T1CON
    ; Timer1 turned on, no prescaler by default
        movlw   0x01
        movwf   T1CON
    
    ; Enable TMR0 and peripheral interrupts, PEIE off until a note is set
        movlw   0xA0
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
        clrf    midiCmdReady

        movlw   0x40
        movwf    noteBendValue

        ; Set all the array elements to -1
        movlw   0xFF
        movwf   noteNumber
        movwf   noteStack1
        movwf   noteStack2
        movwf   noteStack3
        movwf   noteStack4
        movwf   noteStack5
        movwf   noteStack6
        movwf   noteStack7
        
        clrf    toneCmdReady
        
        ;movlw   d'69'           ; Power-on note set to A440
        ;movwf   noteNumber
        ;bsf     toneCmdReady,0

#ifdef TEST_NOTE_STACK
; TEMP TODO
        movlw   0x43
        movwf   noteStack1
        movlw   0x45
        movwf   noteStack2
        movlw   0x55
        movwf   noteStack3
        movlw   0x71
        movwf   noteStack4
        movlw   0x21
        movwf   noteStack5
        movlw   0x4A
        movwf   noteStack6
        movlw   0x3B
        movwf   noteStack7

        movlw   d'10'
        movwf   noteNumber
; Set up a midi note off command
;        movlw   0x90            ; NOTE ON
;        movwf   midiStatus
 ;       movlw   0x77
  ;      movwf   midiNoteBuf
   ;     movlw   0x40            ; make it OFF
    ;    movwf   midiVelocityBuf
        ;bsf     midiCmdReady,0  ; Process command next cycle

        movlw   0x40
        movwf   noteBendValue
        bsf     toneCmdReady,0
#endif
;-----------------------------------
;}

;-----------------------------------
mainloop:
        ;bcf     INTCON,GIE
        ;movlw   4
        ;xorwf   GPIO,f
        ;goto    $-2


;     ------------------------
; FSM Dispatcher
        btfsc   uartDataReady,0
        goto    midiPacketStart
        
        btfsc   midiCmdReady,0
        goto    midiCommandStart
        
        btfsc   toneCmdReady,0
        goto    toneUpdateStart

        goto    mainloop


;     ------------------------
;         Midi Packet FSM
midiPacketStart:
        bcf     uartDataReady,0
;{
        
        ; Check if new byte is status
        btfss   uartData,7
        goto    midiDataByte
        ; This is a status byte, check if it's an allowed status
        clrf    midiState       ; any previous data bytes are invalid
        clrf    midiCmdReady    ; including a completed note command (man these bytes are fast!)
        movf    uartData,w
        movwf   midiStatus      ; store the status word
        ; Check for Note On / Note Off command
        iorlw   0x10        ; don't care if command is ON or OFF
        xorlw   (MIDI_ON_CMD|MIDI_CHANNEL)
        btfsc   STATUS,Z
        goto    midiNoteStatus
        ; Check for Pitch Bend status
        movf    uartData,w
        xorlw   (MIDI_BEND_CMD|MIDI_CHANNEL)
        btfsc   STATUS,Z
        bsf     midiState,2     ; it is a pitch bend, read data bytes
        goto    mainloop
        
midiNoteStatus:
        ; This status is allowed. Start receiving data
        bsf     midiState,0     ; next byte is note number
        goto    mainloop
        
midiDataByte:
        ; Not a midi status byte
        ; See if we are expecting any data bytes
        btfss   midiState,0
        goto    midiVelocityByte
        ; This is a midi note number byte
        movf    uartData,w
        movwf   midiNoteBuf     ; store the note number in buffer
        incf    midiState,f     ; next byte is note velocity
        goto    mainloop
        
midiVelocityByte:
        btfss   midiState,1
        goto    midiPitchLowByte   ; Check if waiting for bend command instead
        ; This is a midi note velocity byte
        movf    uartData,w
        movwf   midiVelocityBuf ; store the note velocity in buffer
        decf    midiState,f     ; next byte is another note number, if we don't get a new status
        bsf     midiCmdReady,0  ; indicate new note/velocity can be processed
        goto    mainloop
        
midiPitchLowByte:
        btfss   midiState,2
        goto    midiPitchHighByte
        ; This is a midi bend command low byte, don't bother saving it
        clrf    midiState
        bsf     midiState,3
        goto    mainloop

midiPitchHighByte:
        btfss   midiState,3
        goto    mainloop
        ; This is a midi bend command high byte, store it
        movf    uartData,w
        movwf   noteBendValue   ; store the bend command
        clrf    midiState    ; next byte is another bend command (rolling status)
        bsf     midiState,2
        incf    noteNumber,w    ; check if current note is -1, note off
        btfss   STATUS,Z
        bsf     toneCmdReady,0  ; note is on, update the tone immediately based on current noteNumber and new noteBendValue
        goto    mainloop

;     ------------------------
;}

;     ------------------------
;         Midi Command Exec
midiCommandStart:
        bcf     midiCmdReady,0
        ; Process the MIDI command (ON or OFF)
        btfss   midiStatus,4        ; MIDI STATUS = 0x90 (NOTE OFF)
        goto    toneOffCommand
        ; We have a new tone ON command (0x80)
        ; Make sure it's not actually an OFF command
        movf    midiVelocityBuf,f
        btfsc   STATUS,Z
        goto    toneOffCommand
        ; Yup, it's a new ON command
toneOnCommand:
        ;  Add the new Note to the top of the noteStack
;{
        ; If it's already in stack #1-6, move to top by shifting part of the stack
        movf    noteStack6,w
        xorwf   midiNoteBuf,w
        btfsc   STATUS,Z
        goto    pushWrite6

        movf    noteStack5,w
        xorwf   midiNoteBuf,w
        btfsc   STATUS,Z
        goto    pushWrite5

        movf    noteStack4,w
        xorwf   midiNoteBuf,w
        btfsc   STATUS,Z
        goto    pushWrite4

        movf    noteStack3,w
        xorwf   midiNoteBuf,w
        btfsc   STATUS,Z
        goto    pushWrite3

        movf    noteStack2,w
        xorwf   midiNoteBuf,w
        btfsc   STATUS,Z
        goto    pushWrite2

        movf    noteStack1,w
        xorwf   midiNoteBuf,w
        btfsc   STATUS,Z
        goto    pushWrite1

        ; If new note is already at top of stack, do nothing
        movf    noteNumber,w
        xorwf   midiNoteBuf,w
        btfsc   STATUS,Z
        goto    mainloop

        ; If new note is at stack 7 or not in the stack, shift the entire stack
        movf    noteStack6,w
        movwf   noteStack7
pushWrite6:
        movf    noteStack5,w
        movwf   noteStack6
pushWrite5:
        movf    noteStack4,w
        movwf   noteStack5
pushWrite4:
        movf    noteStack3,w
        movwf   noteStack4
pushWrite3:
        movf    noteStack2,w
        movwf   noteStack3
pushWrite2:
        movf    noteStack1,w
        movwf   noteStack2
pushWrite1:
        movf    noteNumber,w
        movwf   noteStack1
pushWrite0:
        movf    midiNoteBuf,w
        movwf   noteNumber

        ; Top of stack changed, Update tone value on next loop
        bsf     toneCmdReady,0
        goto    mainloop
;}
;-----------------------------------

;-----------------------------------
toneOffCommand:
        ; Try to remove the given note from the stack
;{
        movf    noteNumber,w
        xorwf   midiNoteBuf,w
        btfsc   STATUS,Z
        goto    popWrite0

        movf    noteStack1,w
        xorwf   midiNoteBuf,w
        btfsc   STATUS,Z
        goto    popWrite1

        movf    noteStack2,w
        xorwf   midiNoteBuf,w
        btfsc   STATUS,Z
        goto    popWrite2

        movf    noteStack3,w
        xorwf   midiNoteBuf,w
        btfsc   STATUS,Z
        goto    popWrite3

        movf    noteStack4,w
        xorwf   midiNoteBuf,w
        btfsc   STATUS,Z
        goto    popWrite4

        movf    noteStack5,w
        xorwf   midiNoteBuf,w
        btfsc   STATUS,Z
        goto    popWrite5

        movf    noteStack6,w
        xorwf   midiNoteBuf,w
        btfsc   STATUS,Z
        goto    popWrite6

        movf    noteStack7,w
        xorwf   midiNoteBuf,w
        btfsc   STATUS,Z
        goto    popWrite7
        
        ; Didn't find it in stack, exit
        goto    mainloop

popWrite0:
        movf    noteStack1,w
        movwf   noteNumber
        bsf     toneCmdReady,0      ; Top of stack changed, need to update tone output
popWrite1:
        movf    noteStack2,w
        movwf   noteStack1
popWrite2:
        movf    noteStack3,w
        movwf   noteStack2
popWrite3:
        movf    noteStack4,w
        movwf   noteStack3
popWrite4:
        movf    noteStack5,w
        movwf   noteStack4
popWrite5:
        movf    noteStack6,w
        movwf   noteStack5
popWrite6:
        movf    noteStack7,w
        movwf   noteStack6
popWrite7:
        movlw   0xFF            ; Fill empty positions with -1 (note off)
        movwf   noteStack7

;-----------------------------------

        incf    noteNumber,w    ; Check if top note is -1, and we really need to turn off
        btfss   STATUS,Z
        goto    mainloop    ; Top of stack is a valid note, already set toneCmdReady if needed
toneOffPitchStop:
        ; Disable the trigger output
        bcf     TRIGGER_OUTPUT
        ; Leave the frequency output unchanged during the decay period
        ;;;; TEMP: Disable the tone output immediately instead of letting it decay
        bcf     INTCON,PEIE
        nop
        bcf     TONE_OUTPUT     ; Disable the tone output pin so the speaker stays non-energized
        bcf     toneCmdReady,0  ; noteNumber is -1, not a valid note to update with
        goto    mainloop
;}
;     ------------------------

;-----------------------------------
;         Tone Timer Update
toneUpdateStart:       ; Set the frequency output based on noteNumber
        bcf     toneCmdReady,0
;{
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
        movf    noteNumber,w
        call    CalculatePitchPeriod
        ; Set Prescaler=3
        movlw   0x03
        movwf   tempPrescaler
        ; Preload = Table + ISR_PS3_OVERHEAD
        movlw   ISR_PS3_OVERHEAD
        goto    toneOnWriteValue

toneOnPS2:
        ; noteNumber >= 12, < 24, Prescaler is 2
        ; Retrieve table value. WREG already contains noteNumber-12, which is positive
        call    CalculatePitchPeriod
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
        call    CalculatePitchPeriod
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
        call    CalculatePitchPeriod
        ; Set Prescaler=0
        ; Preload = Table + ISR_PS0_OVERHEAD
        goto    toneOnWriteValuePS0
        
toneOnPSM1:
        ; Retrieve table value. WREG already contains noteNumber-48, which is positive
        ; Get entry noteNumber-48
        call    CalculatePitchPeriod
        ; Divide table value by 2 to get the half-cycle time
        bsf     STATUS,C            ; Table value is negative, extend sign
        rrf     tempPreloadH,f
        rrf     tempPreloadL,f
        btfss   STATUS,C            ; if we shift out a 1, set the delay bit and round preload up
        goto    toneOnWriteValuePS0
        movlw   TONE_OUTPUT_MASK
        movwf   tempDelay
        incf    tempPreloadL,f
        btfsc   STATUS,Z
        incf    tempPreloadH,f
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
        bsf     INTCON,PEIE
        bsf     INTCON,GIE
        ; Enable the trigger output
        bsf     TRIGGER_OUTPUT
        goto    mainloop
;}
;-----------------------------------




CalculatePitchPeriod:
    ; WREG contains the preload table index
    ; Retrieve the note table
    ; Then apply pitch bend
        movwf   tableAddress
        call    ToneTableLSB
        movwf   tempPreloadL
        movf    tableAddress,w
        call    ToneTableMSB
        movwf   tempPreloadH

        movlw   0x40
        xorwf   noteBendValue,w
        btfsc   STATUS,Z
        return                  ; If Bend value is 64, no modification is needed

        movf    noteBendValue,w
        call    PitchBendTable
        movwf   bendTableValue

        ; Clear M variable, the modifier accumulator
        clrf    bendAmountL
        clrf    bendAmountH
        ; Copy N>>1 into temporary shift register, so we know it's negative
        ; We'll be discarding lower bits during the multiplication, 
        ;   so only using 16 bits for shift and accumulate
        bsf     STATUS,C        ; set the correct sign bit and divide by 2
        rrf     tempPreloadH,w
        movwf   bendTempH
        rrf     tempPreloadL,w
        movwf   bendTempL
        btfsc   tempPreloadL,0        ; round bendTempH:bendTempL up if tempPreloadL ended in 11 before shifting
        btfss   tempPreloadL,1
        goto    SL_NOROUND
        incf    bendTempL,f
        btfsc   STATUS,Z
        incf    bendTempH,f
SL_NOROUND:             ;; 11 or 13 inst setup
        
        ; Calculate M
        ; bendTableValue magnitude is always positive
        ; bendTemp is always negative (because ToneTable value is always negative)
        ; bendAmount always negative
        ; bendAmount is either added to or subtracted from tempPreload based on bendTableValue sign
        
        ;negmac16r  bendTableValue,6,bendTempL,bendTempH,bendAmountL,bendAmountH
        btfss   bendTableValue,6
        goto    $+5
        movf    bendTempL,w     ; bendAmount is always 0 at this stage, just overwrite it
        movwf   bendAmountL
        movf    bendTempH,w
        movwf   bendAmountH
        bsf     STATUS,C
        rrf     bendTempH,f
        rrf     bendTempL,f
        ;negmac16r  bendTableValue,5,bendTempL,bendTempH,bendAmountL,bendAmountH    
        btfss   bendTableValue,5
        goto    $+7
        movf    bendTempL,w
        addwf   bendAmountL,f
        movf    bendTempH,w
        btfsc   STATUS,C
        incfsz  bendTempH,w
        addwf   bendAmountH,f
        bsf     STATUS,C
        rrf     bendTempH,f
        rrf     bendTempL,f
        ;negmac16r  bendTableValue,4,bendTempL,bendTempH,bendAmountL,bendAmountH 
        btfss   bendTableValue,4
        goto    $+7
        movf    bendTempL,w
        addwf   bendAmountL,f
        movf    bendTempH,w
        btfsc   STATUS,C
        incfsz  bendTempH,w
        addwf   bendAmountH,f
        bsf     STATUS,C
        rrf     bendTempH,f
        rrf     bendTempL,f
        ;negmac16r  bendTableValue,3,bendTempL,bendTempH,bendAmountL,bendAmountH    ;; 44 inst first half multiply
        btfss   bendTableValue,3
        goto    $+7
        movf    bendTempL,w
        addwf   bendAmountL,f
        movf    bendTempH,w
        btfsc   STATUS,C
        incfsz  bendTempH,w
        addwf   bendAmountH,f
        bsf     STATUS,C
        rrf     bendTempH,f
        rrf     bendTempL,f
        ;negmac16r  bendTableValue,2,bendTempL,bendTempH,bendAmountL,bendAmountH
        btfss   bendTableValue,2
        goto    $+7
        movf    bendTempL,w
        addwf   bendAmountL,f
        movf    bendTempH,w
        btfsc   STATUS,C
        incfsz  bendTempH,w
        addwf   bendAmountH,f
        bsf     STATUS,C
        rrf     bendTempH,f
        rrf     bendTempL,f
        ;negmac16r  bendTableValue,1,bendTempL,bendTempH,bendAmountL,bendAmountH
        btfss   bendTableValue,1
        goto    $+7
        movf    bendTempL,w
        addwf   bendAmountL,f
        movf    bendTempH,w
        btfsc   STATUS,C
        incfsz  bendTempH,w
        addwf   bendAmountH,f
        bsf     STATUS,C
        rrf     bendTempH,f
        rrf     bendTempL,f
        ;negmac16   bendTableValue,0,bendTempL,bendTempH,bendAmountL,bendAmountH    ;; 30 inst second half multiply
        btfss   bendTableValue,0
        goto    $+7
        movf    bendTempL,w
        addwf   bendAmountL,f
        movf    bendTempH,w
        btfsc   STATUS,C
        incfsz  bendTempH,w
        addwf   bendAmountH,f
        
        ; M = M>>3, arithmetic right shift with round (preserve or restore negative sign)
        btfss   bendAmountL,2
        goto    NOROUND     ; no round if bit 3 (last shifted out) is 0
        movf    bendAmountL,w
        andlw   0x0F
        xorlw   0x04
        btfsc   STATUS,Z
        goto    NOROUND     ; no round if 4 LSBs are 0100 (including the first one kept)
        movlw   0x08        ; yes round, add 8 before discarding bits to the right.
        addwf   bendAmountL,f
        btfsc   STATUS,C
        incf    bendAmountH,f
NOROUND:            ;; 3, 7, or 11 inst rounding
        ;asr16 bendAmountL,bendAmountH
        ;asr16 bendAmountL,bendAmountH
        ;asr16 bendAmountL,bendAmountH        ;; 9 inst right shift
        rrf     bendAmountH,f
        rrf     bendAmountL,f
        rrf     bendAmountH,f
        rrf     bendAmountL,f
        rrf     bendAmountH,f
        rrf     bendAmountL,f
        ; Make sure bendAmount stays negative by setting the upper 3 bits
        movlw   0xE0
        iorwf   bendAmountH,f
        
        ; N = signum(G)?N-(M>>3):N+(M>>3)
        movf    bendAmountL,w
        btfss   bendTableValue,7
        goto    ADDN
SUBN:
        ;sub16 bendAmountL,bendAmountH,tempPreloadL,tempPreloadH
        ;movf    bendAmountL,w
        subwf   tempPreloadL,f
        movf    bendAmountH,w
        btfss   STATUS,C
        incfsz  bendAmountH,w
        subwf   tempPreloadH,f 
        return
ADDN:
        ;add16 bendAmountL,bendAmountH,tempPreloadL,tempPreloadH
        ;movf    bendAmountL,w
        addwf   tempPreloadL,f
        movf    bendAmountH,w
        btfsc   STATUS,C
        incfsz  bendAmountH,w
        addwf   tempPreloadH,f
        return



    ORG     0x0200

ToneTableLSB:
;{
        ; Argument: Place (noteNumber-48)*2+(msb?1:0) in WREG
        ; Results:  WREG = 0 - (Note period in clocks)
        ;bsf     PCLATH,1
        bcf     PCLATH,0
        addwf   PCL,f
        retlw   0xb1 ; Note  48: 6ab1 =  0 - 38223
        retlw   0x13 ; Note  49: 7313 =  0 - 36077
        retlw   0xfc ; Note  50: 7afc =  0 - 34052
        retlw   0x73 ; Note  51: 8273 =  0 - 32141
        retlw   0x7f ; Note  52: 897f =  0 - 30337
        retlw   0x25 ; Note  53: 9025 =  0 - 28635
        retlw   0x6d ; Note  54: 966d =  0 - 27027
        retlw   0x59 ; Note  55: 9c59 =  0 - 25511
        retlw   0xf1 ; Note  56: a1f1 =  0 - 24079
        retlw   0x39 ; Note  57: a739 =  0 - 22727
        retlw   0x34 ; Note  58: ac34 =  0 - 21452
        retlw   0xe8 ; Note  59: b0e8 =  0 - 20248
        retlw   0x59 ; Note  60: b559 =  0 - 19111
        retlw   0x89 ; Note  61: b989 =  0 - 18039
        retlw   0x7e ; Note  62: bd7e =  0 - 17026
        retlw   0x39 ; Note  63: c139 =  0 - 16071
        retlw   0xbf ; Note  64: c4bf =  0 - 15169
        retlw   0x13 ; Note  65: c813 =  0 - 14317
        retlw   0x36 ; Note  66: cb36 =  0 - 13514
        retlw   0x2d ; Note  67: ce2d =  0 - 12755
        retlw   0xf9 ; Note  68: d0f9 =  0 - 12039
        retlw   0x9c ; Note  69: d39c =  0 - 11364
        retlw   0x1a ; Note  70: d61a =  0 - 10726
        retlw   0x74 ; Note  71: d874 =  0 - 10124
        retlw   0xac ; Note  72: daac =  0 -  9556
        retlw   0xc5 ; Note  73: dcc5 =  0 -  9019
        retlw   0xbf ; Note  74: debf =  0 -  8513
        retlw   0x9d ; Note  75: e09d =  0 -  8035
        retlw   0x60 ; Note  76: e260 =  0 -  7584
        retlw   0x09 ; Note  77: e409 =  0 -  7159
        retlw   0x9b ; Note  78: e59b =  0 -  6757
        retlw   0x16 ; Note  79: e716 =  0 -  6378
        retlw   0x7c ; Note  80: e87c =  0 -  6020
        retlw   0xce ; Note  81: e9ce =  0 -  5682
        retlw   0x0d ; Note  82: eb0d =  0 -  5363
        retlw   0x3a ; Note  83: ec3a =  0 -  5062
        retlw   0x56 ; Note  84: ed56 =  0 -  4778
        retlw   0x62 ; Note  85: ee62 =  0 -  4510
        retlw   0x5f ; Note  86: ef5f =  0 -  4257
        retlw   0x4e ; Note  87: f04e =  0 -  4018
        retlw   0x30 ; Note  88: f130 =  0 -  3792
        retlw   0x05 ; Note  89: f205 =  0 -  3579
        retlw   0xce ; Note  90: f2ce =  0 -  3378
        retlw   0x8b ; Note  91: f38b =  0 -  3189
        retlw   0x3e ; Note  92: f43e =  0 -  3010
        retlw   0xe7 ; Note  93: f4e7 =  0 -  2841
        retlw   0x87 ; Note  94: f587 =  0 -  2681
        retlw   0x1d ; Note  95: f61d =  0 -  2531
        retlw   0xab ; Note  96: f6ab =  0 -  2389
        retlw   0x31 ; Note  97: f731 =  0 -  2255
        retlw   0xb0 ; Note  98: f7b0 =  0 -  2128
        retlw   0x27 ; Note  99: f827 =  0 -  2009
        retlw   0x98 ; Note 100: f898 =  0 -  1896
        retlw   0x02 ; Note 101: f902 =  0 -  1790
        retlw   0x67 ; Note 102: f967 =  0 -  1689
        retlw   0xc6 ; Note 103: f9c6 =  0 -  1594
        retlw   0x1f ; Note 104: fa1f =  0 -  1505
        retlw   0x74 ; Note 105: fa74 =  0 -  1420
        retlw   0xc3 ; Note 106: fac3 =  0 -  1341
        retlw   0x0f ; Note 107: fb0f =  0 -  1265
        retlw   0x56 ; Note 108: fb56 =  0 -  1194
        retlw   0x99 ; Note 109: fb99 =  0 -  1127
        retlw   0xd8 ; Note 110: fbd8 =  0 -  1064
        retlw   0x14 ; Note 111: fc14 =  0 -  1004
        retlw   0x4c ; Note 112: fc4c =  0 -   948
        retlw   0x81 ; Note 113: fc81 =  0 -   895
        retlw   0xb3 ; Note 114: fcb3 =  0 -   845
        retlw   0xe3 ; Note 115: fce3 =  0 -   797
        retlw   0x10 ; Note 116: fd10 =  0 -   752
        retlw   0x3a ; Note 117: fd3a =  0 -   710
        retlw   0x62 ; Note 118: fd62 =  0 -   670
        retlw   0x87 ; Note 119: fd87 =  0 -   633
        retlw   0xab ; Note 120: fdab =  0 -   597
        retlw   0xcc ; Note 121: fdcc =  0 -   564
        retlw   0xec ; Note 122: fdec =  0 -   532
        retlw   0x0a ; Note 123: fe0a =  0 -   502
        retlw   0x26 ; Note 124: fe26 =  0 -   474
        retlw   0x41 ; Note 125: fe41 =  0 -   447
        retlw   0x5a ; Note 126: fe5a =  0 -   422
        retlw   0x71 ; Note 127: fe71 =  0 -   399

;-----------------------------------
ToneTableMSB:
        ; Argument: Place (noteNumber-48)*2+(msb?1:0) in WREG
        ; Results:  WREG = 0 - (Note period in clocks)
        ;movlw  0x03
        ;movwf  PCLATH
        addwf   PCL,f
        retlw   0x6a ; Note  48: 6ab1 =  0 - 38223
        retlw   0x73 ; Note  49: 7313 =  0 - 36077
        retlw   0x7a ; Note  50: 7afc =  0 - 34052
        retlw   0x82 ; Note  51: 8273 =  0 - 32141
        retlw   0x89 ; Note  52: 897f =  0 - 30337
        retlw   0x90 ; Note  53: 9025 =  0 - 28635
        retlw   0x96 ; Note  54: 966d =  0 - 27027
        retlw   0x9c ; Note  55: 9c59 =  0 - 25511
        retlw   0xa1 ; Note  56: a1f1 =  0 - 24079
        retlw   0xa7 ; Note  57: a739 =  0 - 22727
        retlw   0xac ; Note  58: ac34 =  0 - 21452
        retlw   0xb0 ; Note  59: b0e8 =  0 - 20248
        retlw   0xb5 ; Note  60: b559 =  0 - 19111
        retlw   0xb9 ; Note  61: b989 =  0 - 18039
        retlw   0xbd ; Note  62: bd7e =  0 - 17026
        retlw   0xc1 ; Note  63: c139 =  0 - 16071
        retlw   0xc4 ; Note  64: c4bf =  0 - 15169
        retlw   0xc8 ; Note  65: c813 =  0 - 14317
        retlw   0xcb ; Note  66: cb36 =  0 - 13514
        retlw   0xce ; Note  67: ce2d =  0 - 12755
        retlw   0xd0 ; Note  68: d0f9 =  0 - 12039
        retlw   0xd3 ; Note  69: d39c =  0 - 11364
        retlw   0xd6 ; Note  70: d61a =  0 - 10726
        retlw   0xd8 ; Note  71: d874 =  0 - 10124
        retlw   0xda ; Note  72: daac =  0 -  9556
        retlw   0xdc ; Note  73: dcc5 =  0 -  9019
        retlw   0xde ; Note  74: debf =  0 -  8513
        retlw   0xe0 ; Note  75: e09d =  0 -  8035
        retlw   0xe2 ; Note  76: e260 =  0 -  7584
        retlw   0xe4 ; Note  77: e409 =  0 -  7159
        retlw   0xe5 ; Note  78: e59b =  0 -  6757
        retlw   0xe7 ; Note  79: e716 =  0 -  6378
        retlw   0xe8 ; Note  80: e87c =  0 -  6020
        retlw   0xe9 ; Note  81: e9ce =  0 -  5682
        retlw   0xeb ; Note  82: eb0d =  0 -  5363
        retlw   0xec ; Note  83: ec3a =  0 -  5062
        retlw   0xed ; Note  84: ed56 =  0 -  4778
        retlw   0xee ; Note  85: ee62 =  0 -  4510
        retlw   0xef ; Note  86: ef5f =  0 -  4257
        retlw   0xf0 ; Note  87: f04e =  0 -  4018
        retlw   0xf1 ; Note  88: f130 =  0 -  3792
        retlw   0xf2 ; Note  89: f205 =  0 -  3579
        retlw   0xf2 ; Note  90: f2ce =  0 -  3378
        retlw   0xf3 ; Note  91: f38b =  0 -  3189
        retlw   0xf4 ; Note  92: f43e =  0 -  3010
        retlw   0xf4 ; Note  93: f4e7 =  0 -  2841
        retlw   0xf5 ; Note  94: f587 =  0 -  2681
        retlw   0xf6 ; Note  95: f61d =  0 -  2531
        retlw   0xf6 ; Note  96: f6ab =  0 -  2389
        retlw   0xf7 ; Note  97: f731 =  0 -  2255
        retlw   0xf7 ; Note  98: f7b0 =  0 -  2128
        retlw   0xf8 ; Note  99: f827 =  0 -  2009
        retlw   0xf8 ; Note 100: f898 =  0 -  1896
        retlw   0xf9 ; Note 101: f902 =  0 -  1790
        retlw   0xf9 ; Note 102: f967 =  0 -  1689
        retlw   0xf9 ; Note 103: f9c6 =  0 -  1594
        retlw   0xfa ; Note 104: fa1f =  0 -  1505
        retlw   0xfa ; Note 105: fa74 =  0 -  1420
        retlw   0xfa ; Note 106: fac3 =  0 -  1341
        retlw   0xfb ; Note 107: fb0f =  0 -  1265
        retlw   0xfb ; Note 108: fb56 =  0 -  1194
        retlw   0xfb ; Note 109: fb99 =  0 -  1127
        retlw   0xfb ; Note 110: fbd8 =  0 -  1064
        retlw   0xfc ; Note 111: fc14 =  0 -  1004
        retlw   0xfc ; Note 112: fc4c =  0 -   948
        retlw   0xfc ; Note 113: fc81 =  0 -   895
        retlw   0xfc ; Note 114: fcb3 =  0 -   845
        retlw   0xfc ; Note 115: fce3 =  0 -   797
        retlw   0xfd ; Note 116: fd10 =  0 -   752
        retlw   0xfd ; Note 117: fd3a =  0 -   710
        retlw   0xfd ; Note 118: fd62 =  0 -   670
        retlw   0xfd ; Note 119: fd87 =  0 -   633
        retlw   0xfd ; Note 120: fdab =  0 -   597
        retlw   0xfd ; Note 121: fdcc =  0 -   564
        retlw   0xfd ; Note 122: fdec =  0 -   532
        retlw   0xfe ; Note 123: fe0a =  0 -   502
        retlw   0xfe ; Note 124: fe26 =  0 -   474
        retlw   0xfe ; Note 125: fe41 =  0 -   447
        retlw   0xfe ; Note 126: fe5a =  0 -   422
        retlw   0xfe ; Note 127: fe71 =  0 -   399
;}
;-----------------------------------

    ORG     0x0300

PitchBendTable:
;{
        ; Argument: WREG = pitch bend command number (0-127)
        ; Results:  pitch bend fractional multiplier in SIGN+MAGNITUDE format
        ;bsf     PCLATH,1
        bsf     PCLATH,0
        addwf   PCL,f
        retlw   0x7D
        retlw   0x7B
        retlw   0x79
        retlw   0x77
        retlw   0x75
        retlw   0x73
        retlw   0x71
        retlw   0x6F
        retlw   0x6D
        retlw   0x6B
        retlw   0x69
        retlw   0x67
        retlw   0x65
        retlw   0x63
        retlw   0x61
        retlw   0x5F
        retlw   0x5D
        retlw   0x5B
        retlw   0x59
        retlw   0x57
        retlw   0x55
        retlw   0x53
        retlw   0x51
        retlw   0x4F
        retlw   0x4D
        retlw   0x4B
        retlw   0x49
        retlw   0x47
        retlw   0x45
        retlw   0x43
        retlw   0x41
        retlw   0x3F
        retlw   0x3D
        retlw   0x3B
        retlw   0x39
        retlw   0x37
        retlw   0x35
        retlw   0x33
        retlw   0x31
        retlw   0x2F
        retlw   0x2D
        retlw   0x2B
        retlw   0x29
        retlw   0x28
        retlw   0x26
        retlw   0x24
        retlw   0x22
        retlw   0x20
        retlw   0x1E
        retlw   0x1C
        retlw   0x1A
        retlw   0x18
        retlw   0x16
        retlw   0x15
        retlw   0x13
        retlw   0x11
        retlw   0xF
        retlw   0xD
        retlw   0xB
        retlw   0x9
        retlw   0x7
        retlw   0x6
        retlw   0x4
        retlw   0x2
        retlw   0x0
        retlw   0x82
        retlw   0x84
        retlw   0x86
        retlw   0x87
        retlw   0x89
        retlw   0x8B
        retlw   0x8D
        retlw   0x8F
        retlw   0x91
        retlw   0x93
        retlw   0x94
        retlw   0x96
        retlw   0x98
        retlw   0x9A
        retlw   0x9C
        retlw   0x9E
        retlw   0x9F
        retlw   0xA1
        retlw   0xA3
        retlw   0xA5
        retlw   0xA7
        retlw   0xA8
        retlw   0xAA
        retlw   0xAC
        retlw   0xAE
        retlw   0xB0
        retlw   0xB1
        retlw   0xB3
        retlw   0xB5
        retlw   0xB7
        retlw   0xB9
        retlw   0xBA
        retlw   0xBC
        retlw   0xBE
        retlw   0xC0
        retlw   0xC1
        retlw   0xC3
        retlw   0xC5
        retlw   0xC7
        retlw   0xC8
        retlw   0xCA
        retlw   0xCC
        retlw   0xCE
        retlw   0xCF
        retlw   0xD1
        retlw   0xD3
        retlw   0xD5
        retlw   0xD6
        retlw   0xD8
        retlw   0xDA
        retlw   0xDB
        retlw   0xDD
        retlw   0xDF
        retlw   0xE1
        retlw   0xE2
        retlw   0xE4
        retlw   0xE6
        retlw   0xE7
        retlw   0xE9
        retlw   0xEB
        retlw   0xEC
        retlw   0xEE
        retlw   0xF0




;}
;-----------------------------------



        END                       ; directive 'end of program'


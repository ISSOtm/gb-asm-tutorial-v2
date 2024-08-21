INCLUDE "hardware.inc"

; BG Tile IDs
RSSET 16
DEF BG_SOLID_0  RB 1
DEF BG_SOLID_1  RB 1
DEF BG_SOLID_2  RB 1
DEF BG_SOLID_3  RB 1
DEF BG_END      RB 1
DEF BG_NEXT     RB 1
DEF BG_EMPTY    RB 1
DEF BG_TICK     RB 1
DEF BG_CROSS    RB 1
DEF BG_INTERNAL RB 1
DEF BG_EXTERNAL RB 1
DEF BG_SIO      RB 1
DEF BG_INBOX    RB 1
DEF BG_OUTBOX   RB 1

; BG map positions (addresses) of various info
DEF DISPLAY_LINK      EQU $9800
DEF DISPLAY_CLOCK_SRC EQU DISPLAY_LINK + 18
DEF DISPLAY_HANDSHAKE EQU DISPLAY_LINK + 19
DEF DISPLAY_TX        EQU DISPLAY_LINK + 32 * 2
DEF DISPLAY_TX_STATE  EQU DISPLAY_TX + 1
DEF DISPLAY_TX_BUFFER EQU DISPLAY_TX + 32
DEF DISPLAY_RX        EQU DISPLAY_LINK + 32 * 5
DEF DISPLAY_RX_STATE  EQU DISPLAY_RX + 1
DEF DISPLAY_RX_BUFFER EQU DISPLAY_RX + 32

; Link finite state machine states enum
DEF DOWN EQU $00
DEF INIT EQU $01
DEF READY EQU $02
DEF RUNNING EQU $03
DEF FINISHED EQU $04
DEF PANIC EQU $05

DEF MSG_SYNC EQU $A0
DEF MSG_SHAKE EQU $B0
DEF MSG_TEST_DATA EQU $C0

DEF STATUS_OK EQU $11
DEF STATUS_ERROR EQU $EE
DEF STATUS_REPORT_COPIES EQU 4

; ANCHOR: handshake-codes
; Handshake code sent by internally clocked device (clock provider)
DEF SHAKE_A EQU $88
; Handshake code sent by externally clocked device
DEF SHAKE_B EQU $77
; ANCHOR_END: handshake-codes


SECTION "Header", ROM0[$100]

	jp EntryPoint

	ds $150 - @, 0 ; Make room for the header

EntryPoint:
	; Do not turn the LCD off outside of VBlank
WaitVBlank:
	ld a, [rLY]
	cp 144
	jp c, WaitVBlank

	; Turn the LCD off
	ld a, 0
	ld [rLCDC], a

	; Copy the tile data
	ld de, Tiles
	ld hl, $9000
	ld bc, TilesEnd - Tiles
	call Memcopy

	; clear BG tilemap
	ld hl, $9800
	ld b, 32
	xor a, a
	ld a, BG_SOLID_0
.clear_row
	ld c, 32
.clear_tile
	ld [hl+], a
	dec c
	jr nz, .clear_tile
	xor a, 1
	dec b
	jr nz, .clear_row

	xor a, a
	ld b, 160
	ld hl, _OAMRAM
.clear_oam
	ld [hli], a
	dec b
	jp nz, .clear_oam

	call LinkInit

	; Turn the LCD on
	ld a, LCDCF_ON | LCDCF_BGON | LCDCF_OBJON
	ld [rLCDC], a

	; During the first (blank) frame, initialize display registers
	ld a, %11100100
	ld [rBGP], a
	ld a, %11100100
	ld [rOBP0], a

	; Initialize global variables
	ld a, 0
	ld [wFrameCounter], a
	ld [wCurKeys], a
	ld [wNewKeys], a

Main:
	ld a, [rLY]
	cp 144
	jp nc, Main
WaitVBlank2:
	ld a, [rLY]
	cp 144
	jp c, WaitVBlank2

	call Input
	call LinkUpdate
	call LinkDisplay
	ld a, [wFrameCounter]
	inc a
	ld [wFrameCounter], a
	jp Main


; ANCHOR: link-init
LinkInit:
	ld a, BG_OUTBOX
	ld [DISPLAY_TX], a
	ld a, BG_INBOX
	ld [DISPLAY_RX], a
	call SioInit
	ei ; Sio requires interrupts to be enabled.
LinkReset:
	ld a, INIT
	ld [wState], a
	ld a, 0
	ld [wCheckPacket], a
	ld [wTxValue], a
	ld [wRxValue], a
	ld [wPacketCount], a
	ld [wErrorCount], a
	ld [wDelay], a
	jp HandshakeDefault
; ANCHOR_END: link-init


; ANCHOR: link-update
LinkUpdate:
	ld a, [wState]
	cp a, DOWN
	ret z
	call SioTick
	ld a, [wState]
	cp a, INIT
	jr z, .link_init
	; if B is pressed, reset
	ld a, [wNewKeys]
	and a, PADF_B
	jp nz, LinkReset
	; handle Sio transfer states
	ld a, [wSioState]
	cp a, SIO_DONE
	jp z, MsgRx
	cp a, SIO_FAILED
	jp z, MsgFailed
	cp a, SIO_IDLE
	jp z, SendNextMessage
	ret
.link_init
	ld a, [wHandshakeState]
	and a, a
	jr nz, .handshake
	; handshake complete
	ld hl, DISPLAY_HANDSHAKE
	ld a, BG_TICK
	ld [hl+], a
	ld a, READY
	ld [wState], a
	jp SendStatusMsg
.handshake:
	call HandshakeUpdate
	ld a, [wFrameCounter]
	and a, %0101_0000
	jr z, .cross
	ld a, BG_EMPTY
	ld [DISPLAY_HANDSHAKE], a
	ret
.cross
	ld a, BG_CROSS
	ld [DISPLAY_HANDSHAKE], a
	ret
; ANCHOR_END: link-update


LinkDisplay:
	ld hl, DISPLAY_LINK
	ld a, [wState] :: ld [hl+], a
	inc hl
	ld a, [wPacketCount]
	ld b, a
	call PrintHex
	ld a, BG_CROSS :: ld [hl+], a
	ld a, [wErrorCount]
	ld b, a
	call PrintHex

	call DrawClockSource

	ld hl, DISPLAY_TX_STATE
	ld a, [wTxValue]
	ld b, a
	call PrintHex
	ret


SendNextMessage:
	ld a, [wState]
	cp a, RUNNING
	jp z, SendSequenceMsg
	cp a, FINISHED
	ret nc
	jp SendStatusMsg


; ANCHOR: link-send-status
SendStatusMsg:
	call SioPacketTxPrepare
	ld a, MSG_SYNC
	ld [hl+], a
	ld a, [wState]
	ld [hl+], a
	jr PacketTransferStart
; ANCHOR_END: link-send-status


; ANCHOR: link-send-test-data
SendSequenceMsg:
	call SioPacketTxPrepare
	ld a, MSG_TEST_DATA
	ld [hl+], a
	ld a, [wTxValue]
	ld [hl+], a
	jr PacketTransferStart
; ANCHOR_END: link-send-test-data


PacketTransferStart:
	call SioPacketTxFinalise
	ld a, 1
	ld [wCheckPacket], a
	ld a, [wPacketCount]
	inc a
	ld [wPacketCount], a
	jp DrawBufferTx


SendStatusReport:
	ld hl, wSioBufferTx
	REPT STATUS_REPORT_COPIES
	ld [hl+], a
	ENDR
	ld a, STATUS_REPORT_COPIES
	call SioTransferStart.CustomCount
	jp DrawBufferTx


; Process received data
; @mut: AF, BC, HL
MsgRx:
	ld a, SIO_IDLE
	ld [wSioState], a

	call DrawBufferRx

	ld a, [wCheckPacket]
	and a, a
	jr nz, .rx_packet
	; no packet check -- status report
	ld hl, wSioBufferRx
	ld c, STATUS_REPORT_COPIES
.read_report_loop
	ld a, [hl+]
	cp a, STATUS_OK
	jr z, .status_ok
	dec c
	jr nz, .read_report_loop
	ld a, [wErrorCount]
	inc a
	ld [wErrorCount], a
	ret
.status_ok
	; Advance tx value if delivered successfully
	ld a, [wTxValue]
	inc a
	ret z
	ld [wTxValue], a
	ret
.rx_packet:
	ld a, 0
	ld [wCheckPacket], a
	call SioPacketRxCheck
	jr z, .check_ok
	; packet checksum didn't match
	ld a, STATUS_ERROR
	jp SendStatusReport
.check_ok
	call ProcessMsg
	ld a, STATUS_OK
	call SendStatusReport
	ret


ProcessMsg:
	ld a, [hl+]
	cp a, MSG_SYNC
	jp z, .sync_msg
	cp a, MSG_TEST_DATA
	jp z, .seq_msg
	; UNKNOWN BAD TIMES
	ld b, a
	ld a, " "
	ld [DISPLAY_RX_STATE], a
	ld [DISPLAY_RX_STATE + 3], a
	ld hl, DISPLAY_RX_STATE + 6
	ld a, BG_SOLID_2 :: ld [hl+], a
	call PrintHex
	ld a, PANIC
	ld [wState], a
	ret
.sync_msg:
	ld a, [hl+]
	ld [wRxStatus], a
	ld b, a
	ld hl, DISPLAY_RX_STATE
	ld a, BG_SOLID_2 :: ld [hl+], a
	call PrintHex
	ld a, " " :: ld [hl+], a
	ld [DISPLAY_RX_STATE + 6], a

;;;;;;;;;;;; remote status updated
	ld a, [wRxStatus]
	ld b, a
	ld a, [wState]
	cp a, READY
	ret nz
	; A = READY, B = [wRxStatus]
	cp a, b
	ret nz
	ld a, RUNNING
	ld [wState], a
	ld a, 0
	ld [wTxValue], a
	ld [wRxValue], a
	ld [wPacketCount], a
	ld [wErrorCount], a
	ret
.seq_msg:
	ld a, [hl+]
	ld [wRxValue], a
	ld b, a

	ld a, " " :: ld [DISPLAY_RX_STATE], a
	ld hl, DISPLAY_RX_STATE + 3
	ld a, BG_SOLID_2 :: ld [hl+], a
	call PrintHex
	ld a, " " :: ld [hl+], a
	ret


MsgFailed:
	ld a, SIO_IDLE
	ld [wSioState], a
	ld a, READY
	ld [wState], a
	call SendStatusMsg
	ret


DrawClockSource:
	ldh a, [rSC]
	and SCF_SOURCE
	ld a, BG_EXTERNAL
	jr z, :+
	ld a, BG_INTERNAL
:
	ld [DISPLAY_CLOCK_SRC], a
	ret


DrawBufferTx:
	ld de, wSioBufferTx
	ld hl, DISPLAY_TX_BUFFER
	ld c, 4
.loop_tx
	ld a, [de]
	inc de
	ld b, a
	call PrintHex
	dec c
	jr nz, .loop_tx
	ret


DrawBufferRx:
	ld de, wSioBufferRx
	ld hl, DISPLAY_RX_BUFFER
	ld c, 4
.loop_rx
	ld a, [de]
	inc de
	ld b, a
	call PrintHex
	dec c
	jr nz, .loop_rx
	ret


; @param B: value
; @param HL: dest
; @mut: AF, HL
PrintHex:
	ld a, b
	swap a
	and a, $0F
	ld [hl+], a
	ld a, b
	and a, $0F
	ld [hl+], a
	ret


Input:
	; Poll half the controller
	ld a, P1F_GET_BTN
	call .onenibble
	ld b, a ; B7-4 = 1; B3-0 = unpressed buttons

	; Poll the other half
	ld a, P1F_GET_DPAD
	call .onenibble
	swap a ; A3-0 = unpressed directions; A7-4 = 1
	xor a, b ; A = pressed buttons + directions
	ld b, a ; B = pressed buttons + directions

	; And release the controller
	ld a, P1F_GET_NONE
	ldh [rP1], a

	; Combine with previous wCurKeys to make wNewKeys
	ld a, [wCurKeys]
	xor a, b ; A = keys that changed state
	and a, b ; A = keys that changed to pressed
	ld [wNewKeys], a
	ld a, b
	ld [wCurKeys], a
	ret

.onenibble
	ldh [rP1], a ; switch the key matrix
	call .knownret ; burn 10 cycles calling a known ret
	ldh a, [rP1] ; ignore value while waiting for the key matrix to settle
	ldh a, [rP1]
	ldh a, [rP1] ; this read counts
	or a, $F0 ; A7-4 = 1; A3-0 = unpressed keys
.knownret
	ret

; Copy bytes from one area to another.
; @param de: Source
; @param hl: Destination
; @param bc: Length
Memcopy:
	ld a, [de]
	ld [hli], a
	inc de
	dec bc
	ld a, b
	or a, c
	jp nz, Memcopy
	ret

Tiles:
	; Hexadecimal digits (0123456789ABCDEF)
	dw $0000, $1c1c, $2222, $2222, $2a2a, $2222, $2222, $1c1c
	dw $0000, $0c0c, $0404, $0404, $0404, $0404, $0404, $0e0e
	dw $0000, $1c1c, $2222, $0202, $0202, $1c1c, $2020, $3e3e
	dw $0000, $1c1c, $2222, $0202, $0c0c, $0202, $2222, $1c1c
	dw $0000, $2020, $2020, $2828, $2828, $3e3e, $0808, $0808
	dw $0000, $3e3e, $2020, $3e3e, $0202, $0202, $0404, $3838
	dw $0000, $0c0c, $1010, $2020, $3c3c, $2222, $2222, $1c1c
	dw $0000, $3e3e, $2222, $0202, $0202, $0404, $0808, $1010
	dw $0000, $1c1c, $2222, $2222, $1c1c, $2222, $2222, $1c1c
	dw $0000, $1c1c, $2222, $2222, $1e1e, $0202, $0202, $0202
	dw $0000, $1c1c, $2222, $2222, $4242, $7e7e, $4242, $4242
	dw $0000, $7c7c, $2222, $2222, $2424, $3a3a, $2222, $7c7c
	dw $0000, $1c1c, $2222, $4040, $4040, $4040, $4242, $3c3c
	dw $0000, $7c7c, $2222, $2222, $2222, $2222, $2222, $7c7c
	dw $0000, $7c7c, $4040, $4040, $4040, $7878, $4040, $7c7c
	dw $0000, $7c7c, $4040, $4040, $4040, $7878, $4040, $4040

	dw `00000000
	dw `00000000
	dw `00000000
	dw `00000000
	dw `00000000
	dw `00000000
	dw `00000000
	dw `00000000

	dw `11111111
	dw `11111111
	dw `11111111
	dw `11111111
	dw `11111111
	dw `11111111
	dw `11111111
	dw `11111111

	dw `22222222
	dw `22222222
	dw `22222222
	dw `22222222
	dw `22222222
	dw `22222222
	dw `22222222
	dw `22222222

	dw `33333333
	dw `33333333
	dw `33333333
	dw `33333333
	dw `33333333
	dw `33333333
	dw `33333333
	dw `33333333

	; end
	dw `30000330
	dw `03000330
	dw `00300330
	dw `00030330
	dw `00300330
	dw `03000330
	dw `30000330
	dw `00000000

	; next
	dw `00003000
	dw `00003300
	dw `33333330
	dw `33333333
	dw `33333330
	dw `00003300
	dw `00003000
	dw `00000000

	; empty
	dw `00000000
	dw `01111110
	dw `21000210
	dw `21000210
	dw `21000210
	dw `21000210
	dw `21111110
	dw `22222200

	; tick
	dw `00000000
	dw `01111113
	dw `21000233
	dw `21000330
	dw `33003310
	dw `21333110
	dw `21131110
	dw `22222200

	; cross
	dw `03000000
	dw `03311113
	dw `21330330
	dw `21033210
	dw `21333210
	dw `33003310
	dw `21111310
	dw `22222200

	; internal
	dw `03333330
	dw `00033000
	dw `00033000
	dw `00033000
	dw `00033000
	dw `00033000
	dw `00033000
	dw `03333330

	; external
	dw `03333330
	dw `03300000
	dw `03300000
	dw `03333300
	dw `03300000
	dw `03300000
	dw `03300000
	dw `03333330

	; Sio
	dw `22223332
	dw `22232223
	dw `20223322
	dw `22220032
	dw `20202023
	dw `20202023
	dw `20200023
	dw `33333332

	; inbox
	dw `33330003
	dw `30000030
	dw `30030300
	dw `30033000
	dw `30033303
	dw `30000003
	dw `30000003
	dw `33333333

	; outbox
	dw `33330333
	dw `30000033
	dw `30000303
	dw `30003000
	dw `30030003
	dw `30000003
	dw `30000003
	dw `33333333

	; link
	dw `03330000
	dw `30003000
	dw `30023200
	dw `30203020
	dw `30203020
	dw `03230020
	dw `00200020
	dw `00022200
TilesEnd:


SECTION "Counter", WRAM0
wFrameCounter: db

SECTION "Input Variables", WRAM0
wCurKeys: db
wNewKeys: db

SECTION "SioTest", WRAM0
wState: db
wCheckPacket: db
wTxValue: db
wRxValue: db

wPacketCount: db
wErrorCount: db
wDelay: db

wRxStatus: db


; ANCHOR: handshake-state
SECTION "Handshake State", WRAM0
wHandshakeState:: db
wHandshakeExpect: db
; ANCHOR_END: handshake-state


; ANCHOR: handshake-begin
SECTION "Handshake Impl", ROM0
; Begin handshake as the default externally clocked device.
HandshakeDefault:
	call SioAbort
	ld a, 0
	ldh [rSC], a
	ld b, SHAKE_B
	ld c, SHAKE_A
	jp HandshakeBegin


; Begin handshake as the clock provider / internally clocked device.
HandshakeAsClockProvider:
	call SioAbort
	ld a, SCF_SOURCE
	ldh [rSC], a
	ld b, SHAKE_A
	ld c, SHAKE_B
	jp HandshakeBegin


; Begin handshake
; @param B: code to send
; @param C: code to expect
HandshakeBegin:
	ld a, 1
	ld [wHandshakeState], a
	ld a, c
	ld [wHandshakeExpect], a
	ld hl, wSioBufferTx
	ld a, MSG_SHAKE
	ld [hl+], a
	ld [hl], b
	ld a, 2
	jp SioTransferStart.CustomCount
; ANCHOR_END: handshake-begin


; ANCHOR: handshake-update
HandshakeUpdate:
	ld a, [wHandshakeState]
	and a, a
	ret z
	; press START: perform handshake as clock provider
	ld a, [wNewKeys]
	bit PADB_START, a
	jr nz, HandshakeAsClockProvider
	; Check if transfer has completed.
	ld a, [wSioState]
	cp a, SIO_DONE
	jr z, HandshakeMsgRx
	cp a, SIO_ACTIVE
	ret z
	; Use DIV to "randomly" try being the clock provider
	ldh a, [rDIV]
	rrca
	jr c, HandshakeAsClockProvider
	jr HandshakeDefault
; ANCHOR_END: handshake-update


; ANCHOR: handshake-xfer-complete
HandshakeMsgRx:
	; flush sio status
	ld a, SIO_IDLE
	ld [wSioState], a
	; Check received value
	ld hl, wSioBufferRx
	ld a, [hl+]
	cp a, MSG_SHAKE
	ret nz
	ld a, [wHandshakeExpect]
	ld b, a
	ld a, [hl+]
	cp a, b
	ret nz
	ld a, 0
	ld [wHandshakeState], a
	ret
; ANCHOR_END: handshake-xfer-complete

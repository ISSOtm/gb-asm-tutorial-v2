INCLUDE "hardware.inc"

; BG Tile IDs
RSSET 16
DEF BG_SOLID_0  RB 1
DEF BG_SOLID_1  RB 1
DEF BG_SOLID_2  RB 1
DEF BG_SOLID_3  RB 1
DEF BG_EMPTY    RB 1
DEF BG_TICK     RB 1
DEF BG_CROSS    RB 1
DEF BG_INTERNAL RB 1
DEF BG_EXTERNAL RB 1
DEF BG_INBOX    RB 1
DEF BG_OUTBOX   RB 1

; BG map positions (addresses) of various info
DEF DISPLAY_LINK      EQU $9800
DEF DISPLAY_LOCAL     EQU DISPLAY_LINK
DEF DISPLAY_REMOTE    EQU DISPLAY_LOCAL + 32
DEF DISPLAY_CLOCK_SRC EQU DISPLAY_LINK + 18
DEF DISPLAY_TX        EQU DISPLAY_LINK + 32 * 2
DEF DISPLAY_TX_STATE  EQU DISPLAY_TX + 1
DEF DISPLAY_TX_BUFFER EQU DISPLAY_TX + 32
DEF DISPLAY_RX        EQU DISPLAY_LINK + 32 * 6
DEF DISPLAY_RX_STATE  EQU DISPLAY_RX + 1
DEF DISPLAY_RX_ERRORS EQU DISPLAY_RX + 18
DEF DISPLAY_RX_BUFFER EQU DISPLAY_RX + 32

; Link finite state machine states enum
DEF LINK_DOWN  EQU $00
DEF LINK_INIT  EQU $01
DEF LINK_UP    EQU $02
DEF LINK_ERROR EQU $03

DEF MSG_SYNC EQU $A0
DEF MSG_SHAKE EQU $B0
DEF MSG_TEST_DATA EQU $C0

; ANCHOR: handshake-codes
; Handshake code sent by internally clocked device (clock provider)
DEF SHAKE_A EQU $88
; Handshake code sent by externally clocked device
DEF SHAKE_B EQU $77
DEF HANDSHAKE_COUNT EQU 5
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

	call Input
	call LinkUpdate

WaitVBlank2:
	ld a, [rLY]
	cp 144
	jp c, WaitVBlank2

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
	ld a, BG_CROSS
	ld [DISPLAY_RX_ERRORS - 1], a
	call SioInit
	ei ; Sio requires interrupts to be enabled.
LinkReset:
	call SioReset
	ld a, LINK_INIT
	ld [wLocal.state], a
	ld a, LINK_DOWN
	ld [wRemote.state], a
	ld a, $FF
	ld [wLocal.tx_id], a
	ld [wLocal.rx_id], a
	ld [wRemote.tx_id], a
	ld [wRemote.rx_id], a
	call ClearTestSequenceResults
	jp HandshakeDefault
; ANCHOR_END: link-init


; ANCHOR: link-update
LinkUpdate:
	; if B is pressed, reset
	ld a, [wNewKeys]
	and a, PADF_B
	jp nz, LinkReset

	call SioTick
	ld a, [wLocal.state]
	cp a, LINK_INIT
	jr z, .link_init
	cp a, LINK_UP
	jr z, .link_up
	ret

.link_up
	; handle Sio transfer states
	ld a, [wSioState]
	cp a, SIO_DONE
	jp z, LinkRx
	cp a, SIO_FAILED
	jp z, LinkError
	cp a, SIO_IDLE
	jp z, SendNextMessage
	ret
.link_init
	ld a, [wHandshakeState]
	and a, a
	jp nz, HandshakeUpdate
	; handshake complete
	ld a, LINK_UP
	ld [wLocal.state], a
	ld a, 0
	ld [wPacketCount], a
	ret
; ANCHOR_END: link-update


LinkDisplay:
	ld hl, DISPLAY_CLOCK_SRC - 3
	ld a, [wPacketCount]
	ld b, a
	call PrintHex
	ld hl, DISPLAY_CLOCK_SRC
	call DrawClockSource
	ld a, [wFrameCounter]
	rrca
	rrca
	and 2
	add BG_SOLID_1
	ld [hl+], a

	ld hl, DISPLAY_LOCAL
	ld a, [wLocal.state]
	call DrawLinkState
	inc hl
	ld a, [wLocal.tx_id]
	ld b, a
	call PrintHex
	inc hl
	ld a, [wLocal.rx_id]
	ld b, a
	call PrintHex

	ld hl, DISPLAY_REMOTE
	ld a, [wRemote.state]
	call DrawLinkState
	inc hl
	ld a, [wRemote.tx_id]
	ld b, a
	call PrintHex
	inc hl
	ld a, [wRemote.rx_id]
	ld b, a
	call PrintHex

	ld hl, DISPLAY_TX_STATE
	ld a, [wTxValue]
	ld b, a
	call PrintHex

	ld hl, DISPLAY_RX_STATE
	ld a, [wRxValue]
	ld b, a
	call PrintHex
	ld hl, DISPLAY_RX_ERRORS
	ld a, [wErrorsRx]
	ld b, a
	call PrintHex
	ld hl, DISPLAY_RX_ERRORS - 3
	ld a, [wErrorsRxMsg]
	ld b, a
	call PrintHex

	ld a, [wFrameCounter]
	and a, $01
	jp z, DrawBufferTx
	jp DrawBufferRx


; ANCHOR: link-send-message
SendNextMessage:
	ld hl, wPacketCount
	ld a, [hl]
	inc [hl]
	and a, $01
	jr z, .sync
.data:
	call SioPacketTxPrepare
	ld a, MSG_TEST_DATA
	ld [hl+], a
	ld a, [wLocal.tx_id]
	ld [hl+], a
	ld a, [wTxValue]
	ld [hl+], a
	call SioPacketTxFinalise
	ret
.sync:
	call SioPacketTxPrepare
	ld a, MSG_SYNC
	ld [hl+], a
	ld a, [wLocal.state]
	ld [hl+], a
	ld a, [wLocal.rx_id]
	ld [hl+], a
	call SioPacketTxFinalise
	ret
; ANCHOR_END: link-send-message


; Process received data
; @mut: AF, BC, HL
LinkRx:
	ld a, SIO_IDLE
	ld [wSioState], a

	call SioPacketRxCheck
	jr z, .check_ok
	ld hl, wErrorsRx
	call u8ptr_IncrementToMax
	ret
.check_ok
	ld a, [hl+]
	cp a, MSG_SYNC
	jr z, .rx_sync
	cp a, MSG_TEST_DATA
	jr z, .rx_test_data
	ld hl, wErrorsRxMsg
	call u8ptr_IncrementToMax
	ret
; handle MSG_SYNC
.rx_sync:
	; always take latest state value
	ld a, [hl+]
	ld [wRemote.state], a
	; does remote ack the ID we sent?
	ld a, [wLocal.tx_id]
	ld b, a
	ld a, [hl+]
	cp a, b
	ret nz
	; save ack'd ID
	ld [wRemote.rx_id], a
	inc b
	ld a, b
	ld [wLocal.tx_id], a
	ld a, [wTxValue]
	inc a
	ld [wTxValue], a
	ret
; handle MSG_TEST_DATA
.rx_test_data:
	; valid data packets must have sequential IDs
	ld a, [wLocal.rx_id]
	ld b, a
	inc b
	ld a, [hl+]
	ld [wRemote.tx_id], a
	cp a, b
	ret nz
	ld [wLocal.rx_id], a
	ld a, [hl+]
	ld [wRxValue], a
	ret


LinkError:
	call SioReset
	ld a, LINK_ERROR
	ld [wLocal.state], a
	ret


ClearTestSequenceResults:
	ld a, 0
	ld [wTxValue], a
	ld [wRxValue], a
	ld [wPacketCount], a
	ld [wErrorsRx], a
	ld [wErrorsRxMsg], a
	ret


; Draw Link state
; @param A: value
; @param HL: dest
; @mut: AF, B, HL
DrawLinkState:
	cp a, LINK_INIT
	jr nz, :+
	ld a, [wHandshakeState]
	and $0F
	ld [hl+], a
	ret
:
	ld b, BG_EMPTY
	cp a, LINK_DOWN
	jr z, .end
	ld b, BG_TICK
	cp a, LINK_UP
	jr z, .end
	ld b, BG_CROSS
	cp a, LINK_ERROR
	jr z, .end
	ld b, a
	jp PrintHex
.end
	ld a, b
	ld [hl+], a
	ret


; @param HL: dest
; @mut AF, HL
DrawClockSource:
	ldh a, [rSC]
	and SCF_SOURCE
	ld a, BG_EXTERNAL
	jr z, :+
	ld a, BG_INTERNAL
:
	ld [hl+], a
	ret


; @mut: AF, BC, DE, HL
DrawBufferTx:
	ld de, wSioBufferTx
	ld hl, DISPLAY_TX_BUFFER
	ld c, 8
.loop_tx
	ld a, [de]
	inc de
	ld b, a
	call PrintHex
	dec c
	jr nz, .loop_tx
	ret


; @mut: AF, BC, DE, HL
DrawBufferRx:
	ld de, wSioBufferRx
	ld hl, DISPLAY_RX_BUFFER
	ld c, 8
.loop_rx
	ld a, [de]
	inc de
	ld b, a
	call PrintHex
	dec c
	jr nz, .loop_rx
	ret


; Increment the byte at [hl], if it's less than 255.
u8ptr_IncrementToMax:
	ld a, [hl]
	inc a
	ret z
	ld [hl], a
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
	dw `03333333
	dw `01223333
	dw `00033300
	dw `00033300
	dw `00023300
	dw `00023300
	dw `03333333
	dw `01223333

	; external
	dw `03333221
	dw `03333333
	dw `03300000
	dw `03333210
	dw `03333330
	dw `03300000
	dw `03333221
	dw `03333333

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
TilesEnd:


SECTION "Counter", WRAM0
wFrameCounter: db

SECTION "Input Variables", WRAM0
wCurKeys: db
wNewKeys: db

SECTION "Link", WRAM0
wTxValue: db
wRxValue: db

wPacketCount: db
; inbound errors (count packets that fail integrity checks)
wErrorsRx: db
; invalid/unexpected message (packet content)
wErrorsRxMsg: db

; Local Link state
wLocal:
	.state: db
	.tx_id: db
	.rx_id: db
; Remote Link state
wRemote:
	.state: db
	.tx_id: db
	.rx_id: db


; ANCHOR: handshake-state
SECTION "Handshake State", WRAM0
wHandshakeState:: db
; ANCHOR_END: handshake-state


; ANCHOR: handshake-begin
SECTION "Handshake Impl", ROM0
; Begin handshake as the default externally clocked device.
HandshakeDefault:
	call SioAbort
	ld a, 0
	ldh [rSC], a
	ld a, HANDSHAKE_COUNT
	ld [wHandshakeState], a
	jr HandshakeSendPacket


; Begin handshake as the clock provider / internally clocked device.
HandshakeAsClockProvider:
	call SioAbort
	ld a, SCF_SOURCE
	ldh [rSC], a
	ld a, HANDSHAKE_COUNT
	ld [wHandshakeState], a
	jr HandshakeSendPacket


HandshakeSendPacket:
	call SioPacketTxPrepare
	ld a, MSG_SHAKE
	ld [hl+], a
	ld b, SHAKE_A
	ldh a, [rSC]
	and a, SCF_SOURCE
	jr nz, :+
	ld b, SHAKE_B
:
	ld [hl], b
	jp SioPacketTxFinalise
; ANCHOR_END: handshake-begin


; ANCHOR: handshake-update
HandshakeUpdate:
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
	call SioPacketRxCheck
	jr nz, .failed
	ld a, [hl+]
	cp a, MSG_SHAKE
	jr nz, .failed
	ld b, SHAKE_A
	ldh a, [rSC]
	and a, SCF_SOURCE
	jr z, :+
	ld b, SHAKE_B
:
	ld a, [hl+]
	cp a, b
	jr nz, .failed
	ld a, [wHandshakeState]
	dec a
	ld [wHandshakeState], a
	jr nz, HandshakeSendPacket
	ret
.failed
	ld a, $FF
	ld [wHandshakeState], a
	ret
; ANCHOR_END: handshake-xfer-complete

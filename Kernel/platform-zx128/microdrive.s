;
;	Sinclair Microdrive Controller
;
;	Doing in software what floppy disk controllers do in hardware!
;
;	A microdrive has up to 254 sectors on it, in reality nearer 200. The
;	blocks are sequential on the tape but in *reverse* order. This is
;	because the formatter writes 254,253,... down to 1, with some
;	overwriting those blocks written first, then verifies the blocks
;	to see how many fitted.
;
;	Some of the blocks will be bad. The formatter in the ROM marks the
;	failed block bad and also the one following.
;
;	To use it like a floppy disc we use sector numbers instead of names
;	as the speccy does. It's not quite the same however. We handle bad
;	blocks by keeping a logical/physical mapping. Each physical block
;	has a physical and logical identifier. In spectrum firmware land
;	there is an "erase" command. When running as a pseudo-floppy we
;	don't have that. Instead we keep a blockmap table in physical 1 and
;	128.
;
		.module microdrive

		.globl _mdv_motor_on
		.globl _mdv_motor_off
		.globl _mdv_bread
		.globl _mdv_bwrite
		.globl mdv_boot

		; imports
		.globl _mdv_sector
		.globl _mdv_buf
		.globl _mdv_hdr_buf
		.globl _mdv_len


;
;	Temporary 512 byte buffer used during boot only
;
MDV_BOOT_BUF	.equ	0xB000

SECTORID	.equ	0x08		; FIXME - set real format up!
CSUM		.equ	0x0E		; FIXME ditto

		.area _CODE

nap_1ms:	push de
		ld de, #87
		jr napl
nap:		push de
napl:		dec de
		ld a, d
		or e
		jr nz,napl
		pop de
		ret
;
;	Must preserve E
;
mdv_csum_hdr:
		xor a
		ld b, #14
		ld hl, #_mdv_hdr_buf
csum_hdr:				; check the header is valid
		add (hl)
		adc #1
		inc hl
		jr z, csum_h0
		dec a
csum_h0:
		djnz csum_hdr
		cp (hl)
		ret

;
;	Load a microdrive sector into the buffer selected by _mdv_buf
;	for _mdv_len (in partial/full counts format). The lead partial goes
;	into _mdv_hdr_buf always
;
;	Note this loads a buffer, any buffer, whatever arrives. It's your
;	problem to decide if it's the buffer you wanted.
;

mdv_seek:	ld b, #8	; we need to see gap for 8 cycles
		dec hl
		ld a, h
		or l
		ret z		; expired
mdv_seek2:
		in a, (0xEF)
		and #4
		jr z, mdv_seek

		; We found a gap bit, celebrate
		djnz mdv_seek2
		; Happy gappy
		
		ld a, #3
		out (0xfe), a
		; Now do the same the other way up
mdv_seeku:	ld b, #6	; we need to see ungap for 6 cycles
		dec hl
		ld a, h
		or l
		ret z		; expired
mdv_seeku2:	in a, (0xEF)
		and #4
		jr nz, mdv_seeku
		djnz mdv_seeku2

		; Gappity gap
		ld a, #5
		out (0xfe), a
		ld a, #0xEE
		out (0xEF), a

		ld b, #0x3C	; Must see a sync within 60 cycles

mdv_sync:	in a, (0xEF)
		and #0x02
		jr z, mdv_sync_go
		djnz mdv_sync
		xor a
		out (0xfe), a
		jr mdv_seek	; back to square one

mdv_sync_go:
		; We are in sync
		ld hl, #_mdv_hdr_buf
		ld de, (_mdv_buf)
		ld bc, (_mdv_len)	; in partial/full pair format
		ld a, #7
		out (0xfe), a
		ld a, c
		ld c, #0xE7

;
;	Q: do we have enough clocks to pull the partial, flip buffer ptr and
;	continue. Seems we probably do
;
		inir			; copy the partial
		sub #1
		jr c, mdv_hdr_only
		ex de, hl		; just about fast enough
mdv_blockread:
		inir
		sub #1
		jr nc, mdv_blockread
		in a, (c)		; grab the checksum
		ld e, a
		; the eagle has landed
mdv_hdr_only:
		xor a
		out (0xfe), a
		ld a, #0xee
		out (0xEF), a
		or a
		ret


;
;	Load the next header, well probably header - you might get the
;	start of a data chunk, in which case try again
;

mdv_get_hdr:	ld hl, #0x0F00		; 15 + no loops
		ld (_mdv_len), hl
		ld hl, #0		; allow a long time to find a header
		call mdv_seek		; they seek him here, they seek him there
		jr z, hdr_fail		; if he ret's z he's off elsewhere


		; fixme: check its a header block !
		call mdv_csum_hdr
		ret z			; Z = good header
		ld a, #2
		ret			; 2 = bad csum
hdr_fail:	
		ld a, #3
		or a
		ret			; 3 = no response, give up for good

;
;	Find a microdrive block by matching header
;	
;	This uses the physical sector number which is *not* the same as
;	our logical one. We'll deal with that later.
;
;	FIXME: we should spot repetitions of the first block# seen so we can
;	give up after 3 loops of the tape exactly.
;
mdv_find_hdr:	ld bc, #2048		; worst case is 4 times round the tape

mdv_find_hdr_l:	push bc
		call mdv_get_hdr	; Fetch any header
		pop bc
		jr nz, mdv_find_hdr_bad	; If it didn't work check the error
		ld hl, #_mdv_hdr_buf
		ld a, (hl)		; Was it data ?
		cp #1
		jr nz, mdv_find_hdr_next; NZ, 1 = not a header
		ld hl, #_mdv_hdr_buf + SECTORID
		ld a, (_mdv_sector)
		cp (hl)
		ret z			; found it
		; Sector header, valid, but not the one we wanted
mdv_find_hdr_next:
		; Count down through our tape scan
		dec bc
		ld a, b
		or c
		jr nz, mdv_find_hdr_l	; keep looking
		inc a			; NZ
		ret
		;
		; Error 3 from mdv_get_hdr means there was nothing found
		; on the tape, so no point trying further. Otherwise it was
		; just a bad header, and we can carry on
		;
mdv_find_hdr_bad:
		cp #3			; 3 = give up now
		jr nz, mdv_find_hdr_next
		or a			; will be > 0
		ret			; NZ

;
;	Load the data for a microdrive block. It's assumed you just found
;	the right header then called this
;
mdv_get_blk:	ld hl, #0x0F02		; 15 + 2 loops (data) + csum in e
		ld (_mdv_len), hl
		ld hl, #0x01F4		; that's the count the IF1 allows
		call mdv_seek
		jr z, hdr_fail		; bad fail
		ld hl, #_mdv_hdr_buf
		ld a, (hl)
		out (0xfe), a
		and #0x01
		jr nz, failblk		; we got another header???
		; Sum the header block
		call mdv_csum_hdr
		jr nz, failblk


		ld hl, (_mdv_buf)	; now the data
		ld bc, #2		; 2 x 256 byte runs
		xor a
csum_data2:
		add (hl)
		adc #1
		inc hl
		jr z, csum_d2
		dec a
csum_d2:
		djnz csum_data2
		dec c
		jr nz, csum_data2
		cp e				; expected csum
		ret z				; good block
		ld a, #2
		out (0xfe), a
			; try again
failblk:
		ret

;
;	Load a sector into memory.
;
mdv_fetch:	call mdv_find_hdr		; nz = not found
		call z, mdv_get_blk		; data if worked
		ret				; done


;
;	Microdrive motor control. This is basically a two wire clock/data
;	pair, shifted through the drives. We have a maximum of eight drives
;	so whenever we select we clock out 8 bits one of which turns on
;	a motor.
;

;
;	Turn all motors off
;
mdv_motors_off:	ld a, #0xff
		jr mdv_motor_a
;
;	Turn on motor for microdrive unit A
;
mdv_motor:	ld bc, #0x08EF			; port EF, 8 cycles
		neg				; Clever way to get the
		add #0x09			; right bit number as used
mdv_motor_a:
		ld  e, a			; by the if1 firmware
;
;	Now we will do 8 cycles of bit banging clock and data
;
mdv_motor_lp:	ld a, #0xEF			; clock it
		out (0xef), a			; select the microdrive sel
						; line
		dec e				; are we there yet
		jr nz, mdv_motor_0		; send zero
;
;	Clock out an "on" bit
;
		ld a,#1
		out (0xF7), a
		ld a, #0xee
		out (c), a			
		call nap_1ms
		ld a, #0xec
		jr mdv_motor_1
;
;	Clock out an "off" bit
;
mdv_motor_0:
		xor a
		out (0xEF), a
		call nap_1ms			; 1ms pulse 0
		ld a, #0xED

mdv_motor_1:	out (c), a
		call nap_1ms
		djnz mdv_motor_lp

;
;	"Spin" up the drive - in our case get the tape to drive speed
;
mdv_spin_up:
		ld bc, #13000
		jp nap


;
;	C language interfaces
;
;	int mdv_motors_off(void)
;
_mdv_motor_off:	call mdv_motors_off
ret0:
		ld hl, #0
		ret

;
;	int mdv_motor_on(uint8_t drive)
;
_mdv_motor_on:	pop hl
		pop af
		push af
		push hl
		call mdv_motor
		jr ret0
;
;	int mdv_read(void)
;	mdv_sector and mdv_buf have been set up ready
;
_mdv_bread:
		call mdv_fetch
		jr z, ret0
		ld l, a
		xor a
		ld h, a
		ret

_mdv_bwrite:
		ld hl, #0xffff		; not done yet
		ret


;
;	Bootstrap logic. This is used when the cartridge powers up
;	in order to load the rest of the kernel from the boot microdrive
;	Interrupts are off, stack is valid. We don't check if the tape
;	causes a stack overwrite, that's operator error!

mdv_boot:
;
;	Spin up the boot volume
;
		ld hl, #MDV_BOOT_BUF
		ld (_mdv_buf), hl
		ld a, #1
		out (0xfe), a		; blue
		call mdv_motor
		ld hl, #1024		; 4 trips round the tape
mdv_boot_loop:
		push hl
;
;	Each loop we fetch a block and if its an 'FK' block then we
;	load it into RAM at the given offset for 512 bytes. We assume that
;	the mdv is created with sufficient interleave we can keep pulling
;	the next block ok
;
		call mdv_get_hdr
		jr nz, mdv_bad
		call mdv_get_blk
		jr nz, mdv_bad
		ld ix, #_mdv_hdr_buf
		ld a, #'F'		; magic for kernel blocks
		cp 4(ix)
		jr nz, not_fk
		ld a, #'K'
		cp 5(ix)
		jr nz, not_fk
		ld hl, #0x5800		; attribute memory
		ld d, #0
		ld e, 1(ix)
		add hl, de
		ld (hl), #0x1f
		inc hl
		ld (hl), #0x1f
;
;	We may ldir over _mdv_hdr_buf so do the attributes then
;	follow up with the block copy
;
		ld a, 1(ix)
		out (0xfe), a		; loading stripes
		ld d, a			; high byte of address
		ld e, #0
		ld hl, #MDV_BOOT_BUF
		ld bc, #512
		ldir
		call done_all		; check if we are complete
		jr z, mdv_boot_done
		ld hl, #MDV_BOOT_BUF		; we may have reloaded over this
		ld (_mdv_buf), hl
not_fk:		pop hl
		dec hl
		ld a, h
		or l
		jr nz, mdv_boot_loop
mdv_fail:	ld a, #2
		out (0xfe), a		; red border
failed:		jr failed

mdv_bad:	cp #3
		jr z, mdv_fail		; give up return
		jr not_fk

mdv_boot_done:
		xor a
		out (0xFE), a
		ret

done_all:	ld hl, #0x585B		; check data is loaded
		ld b, #0x44
		ld a, #0x1f
done_1:		cp (hl)
		ret nz
		inc hl
		djnz done_1
		ld hl, #0x58C0		; and code
		ld b, #0x3f
done_2:		cp (hl)
		ret nz
		inc hl
		djnz done_2
		ret			; Z


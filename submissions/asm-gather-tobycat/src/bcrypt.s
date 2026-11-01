# bcrypt with N interleaved lanes: every lane's table lookups overlap in the out-of-order window, so
# several hashes at once cost far less per hash than one at a time. Generated per N by macros.
.include "defs.inc"
.set LS,4352        # lane stride: P+S, then the expanded key and salt
.set L_S,72
.set L_KEYP,4168
.set L_SALTP,4240
.set L_SALTX,4312
.section .rodata
.balign 64
bf_init:
.include "bf_tables.inc"
.set bf_init_len,.-bf_init
bc_ct: .ascii "OrpheanBeholderScryDoubt"
.text

# Two Blowfish rounds of lane n, with L in the low half of reg and R in the high half. XOR commutes, so
# P[p] and P[p+1] go in together with one 64-bit load; alternating which half feeds F needs no rotate.
.macro LP r64,n,p
  xor \r64,[rbx+\n*LS+\p*4]
.endm
.macro LF_BODY n
  movzx ecx,al
  movzx edx,ah
  shr eax,16
  movzx esi,ah
  movzx eax,al
  mov edi,[rbx+\n*LS+L_S+rsi*4]
  add edi,[rbx+\n*LS+L_S+1024+rax*4]
  xor edi,[rbx+\n*LS+L_S+2048+rdx*4]
  add edi,[rbx+\n*LS+L_S+3072+rcx*4]
.endm
# high half ^= F(low half)
.macro LA r64,r32,n
  mov eax,\r32
  LF_BODY \n
  shl rdi,32
  xor \r64,rdi
.endm
# low half ^= F(high half)
.macro LB r64,n
  mov rax,\r64
  shr rax,32
  LF_BODY \n
  xor \r64,rdi
.endm
.macro LP_N N,p
  LP r8,0,\p
  .if \N>1
  LP r9,1,\p
  .endif
  .if \N>2
  LP r10,2,\p
  .endif
  .if \N>3
  LP r11,3,\p
  .endif
  .if \N>4
  LP r12,4,\p
  .endif
  .if \N>5
  LP r13,5,\p
  .endif
.endm
.macro LA_N N
  LA r8,r8d,0
  .if \N>1
  LA r9,r9d,1
  .endif
  .if \N>2
  LA r10,r10d,2
  .endif
  .if \N>3
  LA r11,r11d,3
  .endif
  .if \N>4
  LA r12,r12d,4
  .endif
  .if \N>5
  LA r13,r13d,5
  .endif
.endm
.macro LB_N N
  LB r8,0
  .if \N>1
  LB r9,1
  .endif
  .if \N>2
  LB r10,2
  .endif
  .if \N>3
  LB r11,3
  .endif
  .if \N>4
  LB r12,4
  .endif
  .if \N>5
  LB r13,5
  .endif
.endm
.macro LANE_END r64,n
  xor \r64,[rbx+\n*LS+16*4]
  ror \r64,32
  mov [rbx+\n*LS+r14*4],\r64
.endm
.macro LANE_SALT r64,n
  xor \r64,[rbx+\n*LS+L_SALTX+r15]
.endm
# Encrypt the running block through P+S once for each of its 521 pairs, writing them back.
.macro BF_LOOP N
bf_loop\N:
  xor r8d,r8d
  xor r9d,r9d
  xor r10d,r10d
  xor r11d,r11d
  xor r12d,r12d
  xor r13d,r13d
  xor r14d,r14d
1:mov r15,r14
  and r15d,2
  shl r15d,2
  LANE_SALT r8,0
  .if \N>1
  LANE_SALT r9,1
  .endif
  .if \N>2
  LANE_SALT r10,2
  .endif
  .if \N>3
  LANE_SALT r11,3
  .endif
  .if \N>4
  LANE_SALT r12,4
  .endif
  .if \N>5
  LANE_SALT r13,5
  .endif
  .irp p,0,2,4,6,8,10,12,14
  LP_N \N,\p
  LA_N \N
  LB_N \N
  .endr
  LANE_END r8,0
  .if \N>1
  LANE_END r9,1
  .endif
  .if \N>2
  LANE_END r10,2
  .endif
  .if \N>3
  LANE_END r11,3
  .endif
  .if \N>4
  LANE_END r12,4
  .endif
  .if \N>5
  LANE_END r13,5
  .endif
  add r14,2
  cmp r14,1042
  jb 1b
  ret
.endm
BF_LOOP 1
BF_LOOP 2
BF_LOOP 3
BF_LOOP 4
BF_LOOP 5
BF_LOOP 6
.section .rodata
.balign 8
bf_loops: .quad bf_loop1,bf_loop2,bf_loop3,bf_loop4,bf_loop5,bf_loop6
.text

# cyc_words rdi out[18 words], rsi bytes, rdx len: big-endian words cycling over the bytes.
cyc_words:
  xor ecx,ecx            # word index
  xor r8d,r8d            # byte index
1:xor eax,eax
  mov r9d,4
2:shl eax,8
  movzx r10d,byte ptr [rsi+r8]
  or eax,r10d
  inc r8
  cmp r8,rdx
  jb 3f
  xor r8d,r8d
3:dec r9d
  jnz 2b
  mov [rdi+rcx*4],eax
  inc ecx
  cmp ecx,18
  jne 1b
  ret

# For lanes 0..N-1 (N at [rsp]): P ^= the 18 words at offset off.
.macro XOR_P off
  xor ecx,ecx
771:mov rdx,rcx
  imul rdx,rdx,LS
  add rdx,rbx
  xor esi,esi
772:mov rax,[rdx+\off+rsi*8]
  xor [rdx+rsi*8],rax
  inc esi
  cmp esi,9
  jne 772b
  inc ecx
  cmp rcx,[rsp]
  jne 771b
.endm

# bcrypt_run rdi descriptors, rsi N (1-6), rdx cost, r8 lane memory (LS*6).
# Descriptor (64 bytes): +0 key ptr, +8 key len incl. trailing NUL (1..72), +16 salt[16], +32 out[24].
.set BD_KEY,0
.set BD_KLEN,8
.set BD_SALT,16
.set BD_OUT,32
.set BD_SIZE,64
.globl bcrypt_run
bcrypt_run:
  push rbx
  push rbp
  push r12
  push r13
  push r14
  push r15
  sub rsp,32
  mov [rsp],rsi          # N
  mov ecx,edx
  mov eax,1
  shl rax,cl
  mov [rsp+8],rax        # rounds
  mov [rsp+16],rdi       # descriptors
  mov rbx,r8
  xor r12d,r12d
1:mov r13,r12
  imul r13,r13,LS
  add r13,rbx
  mov rdi,r13
  lea rsi,[rip+bf_init]
  mov ecx,bf_init_len
  call mcpy
  mov r14,r12
  shl r14,6
  add r14,[rsp+16]
  lea rdi,[r13+L_KEYP]
  mov rsi,[r14+BD_KEY]
  mov rdx,[r14+BD_KLEN]
  call cyc_words
  lea rdi,[r13+L_SALTP]
  lea rsi,[r14+BD_SALT]
  mov edx,16
  call cyc_words
  movdqu xmm0,[r13+L_SALTP]
  movdqu [r13+L_SALTX],xmm0
  inc r12
  cmp r12,[rsp]
  jne 1b
  # ExpandState(salt, key)
  XOR_P L_KEYP
  mov rax,[rsp]
  lea rcx,[rip+bf_loops]
  call qword ptr [rcx+rax*8-8]
  # from now on the block is not salted
  xor ecx,ecx
2:mov rdx,rcx
  imul rdx,rdx,LS
  add rdx,rbx
  xor eax,eax
  mov [rdx+L_SALTX],rax
  mov [rdx+L_SALTX+8],rax
  inc rcx
  cmp rcx,[rsp]
  jne 2b
3:XOR_P L_KEYP
  mov rax,[rsp]
  lea rcx,[rip+bf_loops]
  call qword ptr [rcx+rax*8-8]
  XOR_P L_SALTP
  mov rax,[rsp]
  lea rcx,[rip+bf_loops]
  call qword ptr [rcx+rax*8-8]
  dec qword ptr [rsp+8]
  jnz 3b
  # 64 encryptions of the magic text, per lane
  xor r12d,r12d
4:mov r14,r12
  shl r14,6
  add r14,[rsp+16]
  add r14,BD_OUT
  mov r13,r12
  imul r13,r13,LS
  add rbx,r13
  xor r15d,r15d          # block 0..2
5:lea rax,[rip+bc_ct]
  mov r8d,[rax+r15*8]
  bswap r8d
  mov r9d,[rax+r15*8+4]
  bswap r9d
  shl r9,32
  or r8,r9
  mov ebp,64
6:.irp p,0,2,4,6,8,10,12,14
  LP r8,0,\p
  LA r8,r8d,0
  LB r8,0
  .endr
  xor r8,[rbx+16*4]
  ror r8,32
  dec ebp
  jnz 6b
  mov eax,r8d
  bswap eax
  mov [r14+r15*8],eax
  shr r8,32
  bswap r8d
  mov [r14+r15*8+4],r8d
  inc r15
  cmp r15,3
  jne 5b
  sub rbx,r13
  inc r12
  cmp r12,[rsp]
  jne 4b
  add rsp,32
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbp
  pop rbx
  ret

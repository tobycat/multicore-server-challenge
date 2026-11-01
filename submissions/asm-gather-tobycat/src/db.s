# DB threads. Workers queue jobs; blocking reader threads take a whole family at once, run it as one
# statement and render every response; one writer group-commits; bcrypt threads run multi-lane batches.
.include "defs.inc"
.set FAST_GATHER_MS,2
# Article views run the list statement but queue apart, so they get short batches of their own instead of waiting on lists.
.set Q_ART,NFAM
.set Q_GLOB,NFAM+1
.set NQ,NFAM+4
.set Q_WRITE,NFAM+2
.set Q_BC,NFAM+3
.set Q_HEAD,0
.set Q_TAIL,8
.set Q_CNT,16
.set Q_SIZE,32
.bss
.balign 64
q_lock:  .skip 64
queues:  .skip Q_SIZE*NQ
.balign 64
r_seq:   .skip 64
r_idle:  .skip 64
w_seq:   .skip 64
w_idle:  .skip 64
b_seq:   .skip 64
b_idle:  .skip 64
b_poll:  .skip 8
.globl g_gather_ms,g_workers
g_gather_ms: .skip 8
g_bc_seq: .skip 8
.globl g_gz_mode,g_gz_on
g_gz_mode: .skip 8       # 0 never, 1 always, 2 adaptive
g_gz_on: .skip 8
g_tx: .skip 8            # response body bytes since the last controller tick, before compression
g_gz_next: .skip 8
g_gz_last: .skip 8
g_gz_retrans: .skip 8
.globl g_read_batch
g_read_batch: .skip 8
.globl g_bcrypt_nice
g_bcrypt_nice: .skip 8
g_workers: .skip 8           # base of the worker array
.section .rodata
# statement names
n_r0: .asciz "r0"
n_r1: .asciz "r1"
n_r2: .asciz "r2"
n_r3: .asciz "r3"
n_r4: .asciz "r4"
n_r5: .asciz "r5"
n_r6: .asciz "r6"
n_r7: .asciz "r7"
n_r8: .asciz "r8"
n_w0: .asciz "w0"
n_w1: .asciz "w1"
n_w2: .asciz "w2"
n_w3: .asciz "w3"
n_w4: .asciz "w4"
n_w5: .asciz "w5"
n_w6: .asciz "w6"
n_w7: .asciz "w7"
n_w8: .asciz "w8"
n_w9: .asciz "w9"
n_wa: .asciz "wa"
n_wt: .asciz "wt"
.balign 8
read_stmts:
.quad n_r0,sql_mega,n_r1,sql_feed,n_r2,sql_comments,n_r3,sql_profile,n_r4,sql_user,n_r5,sql_login,n_r6,sql_tags,n_r7,sql_article,n_r8,sql_global,0,0
write_stmts:
.quad n_w0,sql_w_reg,n_w1,sql_w_upd,n_w2,sql_w_fol,n_w3,sql_w_unfol,n_w4,sql_w_fav,n_w5,sql_w_unfav
.quad n_w6,sql_w_art,n_w7,sql_w_artupd,n_w8,sql_w_artdel,n_w9,sql_w_cmt,n_wa,sql_w_cmtdel,n_wt,sql_w_tags,0,0
# parameter specs: 1 viewer, 2 J_A, 3 J_B, 4 J_SUB, 0x10+n string slot n. Zero-terminated.
fam_params:
.quad p_mega,p_feed,p_cm,p_cm,p_user,p_login,p_none,p_mega,p_mega
p_mega: .byte 4,1,2,3,0x10,0
p_feed: .byte 1,2,3,0
p_cm:   .byte 0x10,1,0
p_user: .byte 1,0
p_login:.byte 0x11,0
p_none: .byte 0
# ms of priority per queue: lists, feed, comments, profile, user, login, tags, article views, global list
fam_bonus: .byte 0,10,5,10,10,10,10,5,5
.balign 8
wr_params:  # indexed by kind-K_REG: name, params
.quad n_w0,pw0,n_w1,pw1,n_w2,pw2,n_w3,pw2,n_w4,pw2,n_w5,pw2,n_w6,pw6,n_w7,pw7,n_w8,pw8,n_w9,pw9,n_wa,pwa
pw0: .byte 0x10,0x11,0x12,0
pw1: .byte 1,0x11,0x10,0x12,0x13,0x14,0
pw2: .byte 1,0x10,0
pw6: .byte 1,0x11,0x12,0x13,0x14,0
pw7: .byte 0x10,0x11,0x12,0x13,1,0
pw8: .byte 0x10,1,0
pw9: .byte 1,0x10,0x11,0
pwa: .byte 2,0x10,1,0
pwt: .byte 0x14,0
.balign 8
fam_names: .quad n_r0,n_r1,n_r2,n_r3,n_r4,n_r5,n_r6,n_r7,n_r8
.text

# enqueue rdi job: routes by kind. Preserves rbx, rbp, r12-r15.
.globl enqueue
enqueue:
  mov eax,[rdi+J_KIND]
  mov edx,eax
  cmp eax,NFAM
  jb 0f
  mov edx,Q_BC
  cmp eax,K_BC_HASH
  jae 1f
  mov edx,Q_WRITE
  jmp 1f
0:test eax,eax
  jnz 1f
  mov edx,Q_ART
  cmp dword ptr [rdi+J_SUB],SUB_SLUG
  je 1f
  mov edx,Q_GLOB
  cmp dword ptr [rdi+J_SUB],0
  je 1f
  xor edx,edx
1:imul r8d,edx,Q_SIZE
  lea r9,[rip+queues]
  add r9,r8
  mov qword ptr [rdi+J_NEXT],0
  mov rsi,rdi
  lea rdi,[rip+q_lock]
  call spin_lock
  mov rax,[r9+Q_TAIL]
  test rax,rax
  jz 2f
  mov [rax+J_NEXT],rsi
  jmp 3f
2:mov [r9+Q_HEAD],rsi
3:mov [r9+Q_TAIL],rsi
  inc qword ptr [r9+Q_CNT]
  # choose the wait group
  lea rdi,[rip+r_seq]
  lea rsi,[rip+r_idle]
  cmp edx,Q_WRITE
  jb 4f
  lea rdi,[rip+w_seq]
  lea rsi,[rip+w_idle]
  je 4f
  lea rdi,[rip+b_seq]
  lea rsi,[rip+b_idle]
4:inc dword ptr [rdi]
  mov eax,[rsi]
  mov dword ptr [rip+q_lock],0
  test eax,eax
  jz 5f
  mov esi,1
  jmp futex_wake
5:ret

# q_detach r9=queue (lock held), rsi=max -> rax list head, rdx count; list is NULL-terminated.
q_detach:
  mov rax,[r9+Q_HEAD]
  mov rdx,[r9+Q_CNT]
  cmp rdx,rsi
  ja 1f
  mov qword ptr [r9+Q_HEAD],0
  mov qword ptr [r9+Q_TAIL],0
  mov qword ptr [r9+Q_CNT],0
  ret
1:mov rcx,rax
  mov r8,rsi
2:dec r8
  jz 3f
  mov rcx,[rcx+J_NEXT]
  jmp 2b
3:mov r8,[rcx+J_NEXT]
  mov [r9+Q_HEAD],r8
  mov qword ptr [rcx+J_NEXT],0
  sub [r9+Q_CNT],rsi
  mov rdx,rsi
  ret

# deliver rbx job: hand a finished job to its worker. Sets the notify mask in ctx rbp.
deliver:
  mov eax,[rbx+J_WID]
  mov ecx,eax
  mov edx,1
  shl rdx,cl
  or [rbp+PG_MASK],rdx
  imul rax,rax,W_SIZE
  add rax,[rip+g_workers]
  mov rcx,[rax+W_INBOX]
1:mov [rbx+J_NEXT],rcx
  mov rdx,rax
  mov rax,rcx
  lock cmpxchg [rdx+W_INBOX],rbx
  mov rcx,rax
  mov rax,rdx
  jne 1b
  ret

# flush_notify rbp: wake every worker that received jobs
flush_notify:
  push rbx
  mov rbx,[rbp+PG_MASK]
  mov qword ptr [rbp+PG_MASK],0
1:test rbx,rbx
  jz 3f
  bsf rax,rbx
  btr rbx,rax
  imul rax,rax,W_SIZE
  add rax,[rip+g_workers]
  mov ecx,1
  xchg ecx,[rax+W_NOTIFIED]
  test ecx,ecx
  jnz 1b
  mov edi,[rax+W_EVFD]
  lea rsi,[rip+one64]
  mov edx,8
  SYS SYS_WRITE
  jmp 1b
3:pop rbx
  ret
.section .rodata
.balign 8
one64: .quad 1
.text

# ---------------------------------------------------------------- rendering helpers
# Rows: rbx walks the columns. All preserve rbx-advance semantics and r12-r15, rbp.
fld:                  # -> rsi ptr, ecx len (or -1 for NULL)
  mov ecx,[rbx]
  bswap ecx
  lea rsi,[rbx+4]
  add rbx,4
  cmp ecx,-1
  je 1f
  add rbx,rcx
1:ret
r_str:                # non-null string
  call fld
  jmp json_esc
r_nstr:               # nullable string
  call fld
  cmp ecx,-1
  jne json_esc
  mov dword ptr [rdi],0x6c6c756e
  add rdi,4
  ret
r_int:                # int8
  call fld
  mov rsi,[rsi]
  bswap rsi
  jmp put_u64
r_bool:               # bool
  call fld
  cmp byte ptr [rsi],0
  mov dword ptr [rdi],0x65757274
  je 1f
  add rdi,4
  ret
1:mov dword ptr [rdi],0x736c6166
  mov byte ptr [rdi+4],'e'
  add rdi,5
  ret

# put_bool rdi out, eax value
put_bool:
  test eax,eax
  mov dword ptr [rdi],0x65757274
  jz 1f
  add rdi,4
  ret
1:mov dword ptr [rdi],0x736c6166
  mov byte ptr [rdi+4],'e'
  add rdi,5
  ret

# two digits of eax at rdi
.macro D2
  xor edx,edx
  mov ecx,10
  div ecx
  add al,'0'
  add dl,'0'
  mov [rdi],al
  mov [rdi+1],dl
  add rdi,2
.endm
# r_ts: timestamptz (microseconds since 2000-01-01 UTC) as "YYYY-MM-DDTHH:MM:SS.mmmZ"
r_ts:
  call fld
  mov rax,[rsi]
  bswap rax
  push r12
  push r13
  mov rcx,1000000
  cqo
  idiv rcx
  test rdx,rdx
  jns 1f
  add rdx,rcx
  dec rax
1:mov r12,rdx            # micros
  add rax,946684800
  mov rcx,86400
  cqo
  idiv rcx
  test rdx,rdx
  jns 2f
  add rdx,rcx
  dec rax
2:mov r13,rdx            # seconds of day
  # civil from days (Hinnant)
  add rax,719468
  mov rcx,146097
  cqo
  idiv rcx               # rax era, rdx doe (no dates before 0000)
  mov r8,rax
  mov r9,rdx             # doe
  mov rax,r9
  mov ecx,1460
  xor edx,edx
  div rcx
  mov r10,rax
  mov rax,r9
  mov ecx,36524
  xor edx,edx
  div rcx
  sub r10,rax
  mov rax,r9
  mov ecx,146096
  xor edx,edx
  div rcx
  add r10,rax
  neg r10
  add r10,r9             # yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365
  mov rax,r10
  mov ecx,365
  xor edx,edx
  div rcx
  mov r10,rax            # yoe
  imul r11,r8,400
  add r11,r10            # y
  imul rax,r10,365
  mov rcx,r10
  shr rcx,2
  add rax,rcx
  mov rcx,r10
  push rax
  mov rax,rcx
  xor edx,edx
  mov ecx,100
  div rcx
  mov rcx,rax
  pop rax
  sub rax,rcx
  sub r9,rax             # doy
  lea rax,[r9*4+r9]
  lea rax,[rax+2]        # 5*doy+2
  xor edx,edx
  mov ecx,153
  div rcx
  mov r10,rax            # mp
  imul rax,r10,153
  add rax,2
  xor edx,edx
  mov ecx,5
  div rcx
  sub r9,rax
  inc r9                 # day
  lea r8,[r10+3]
  cmp r8,12
  jbe 3f
  sub r8,12
3:cmp r8,2
  ja 4f
  inc r11
4:mov byte ptr [rdi],'"'
  inc rdi
  mov rax,r11
  xor edx,edx
  mov ecx,100
  div rcx
  mov r10,rdx
  D2
  mov rax,r10
  D2
  mov byte ptr [rdi],'-'
  inc rdi
  mov rax,r8
  D2
  mov byte ptr [rdi],'-'
  inc rdi
  mov rax,r9
  D2
  mov byte ptr [rdi],'T'
  inc rdi
  mov rax,r13
  xor edx,edx
  mov ecx,3600
  div rcx
  mov r13,rdx
  D2
  mov byte ptr [rdi],':'
  inc rdi
  mov rax,r13
  xor edx,edx
  mov ecx,60
  div rcx
  mov r13,rdx
  D2
  mov byte ptr [rdi],':'
  inc rdi
  mov rax,r13
  D2
  mov byte ptr [rdi],'.'
  inc rdi
  mov rax,r12
  xor edx,edx
  mov ecx,1000
  div rcx                # ms
  xor edx,edx
  mov ecx,100
  div ecx
  add al,'0'
  mov [rdi],al
  inc rdi
  mov eax,edx
  D2
  mov word ptr [rdi],0x225a   # Z"
  add rdi,2
  pop r13
  pop r12
  ret

# r_tags: binary text[] as a JSON array
r_tags:
  call fld
  mov byte ptr [rdi],'['
  inc rdi
  push r12
  push r13
  mov eax,[rsi]
  test eax,eax
  jz 3f                  # ndim 0: empty
  mov r12d,[rsi+12]
  bswap r12d             # element count
  lea r13,[rsi+20]
  mov eax,r12d
  test eax,eax
  jz 3f
1:mov ecx,[r13]
  bswap ecx
  lea rsi,[r13+4]
  lea r13,[rsi+rcx]
  call json_esc
  dec r12d
  jz 3f
  mov byte ptr [rdi],','
  inc rdi
  jmp 1b
3:mov byte ptr [rdi],']'
  inc rdi
  pop r13
  pop r12
  ret

# r_article: rbx at the slug column of an article row; rax bit0 favorited, bit1 following, bit2 include body.
r_article:
  push r12
  mov r12d,eax
  LIT "{\"slug\":"
  call r_str
  LIT ",\"title\":"
  call r_str
  LIT ",\"description\":"
  call r_str
  test r12d,4
  jz 1f
  LIT ",\"body\":"
  call r_str
  jmp 2f
1:call fld
2:LIT ",\"createdAt\":"
  call r_ts
  LIT ",\"updatedAt\":"
  call r_ts
  LIT ",\"tagList\":"
  call r_tags
  LIT ",\"favorited\":"
  mov eax,r12d
  and eax,1
  call put_bool
  LIT ",\"favoritesCount\":"
  call r_int
  LIT ",\"author\":{\"username\":"
  call r_str
  LIT ",\"bio\":"
  call r_nstr
  LIT ",\"image\":"
  call r_nstr
  LIT ",\"following\":"
  mov eax,r12d
  shr eax,1
  and eax,1
  call put_bool
  mov word ptr [rdi],0x7d7d
  add rdi,2
  pop r12
  ret

# Response assembly -----------------------------------------------------------------------------
.section .rodata
st200: .ascii "200 OK"
st201: .ascii "201 Created"
st401: .ascii "401 Unauthorized"
st403: .ascii "403 Forbidden"
st404: .ascii "404 Not Found"
st413: .ascii "413 Payload Too Large"
st422: .ascii "422 Unprocessable Entity"
st500: .ascii "500 Internal Server Error"
st503: .ascii "503 Service Unavailable"
.text
# http_head rdi out, esi status, rdx body length -> rdi advanced
.globl http_head
http_head:
  push rbx
  push r12
  mov ebx,esi
  mov r12,rdx
  LIT "HTTP/1.1 "
  lea rsi,[rip+st200]
  mov ecx,6
  cmp ebx,200
  je 1f
  lea rsi,[rip+st201]
  mov ecx,11
  cmp ebx,201
  je 1f
  lea rsi,[rip+st401]
  mov ecx,16
  cmp ebx,401
  je 1f
  lea rsi,[rip+st403]
  mov ecx,13
  cmp ebx,403
  je 1f
  lea rsi,[rip+st404]
  mov ecx,13
  cmp ebx,404
  je 1f
  lea rsi,[rip+st413]
  mov ecx,21
  cmp ebx,413
  je 1f
  lea rsi,[rip+st422]
  mov ecx,24
  cmp ebx,422
  je 1f
  lea rsi,[rip+st503]
  mov ecx,23
  cmp ebx,503
  je 1f
  lea rsi,[rip+st500]
  mov ecx,25
1:call mcpy
  LIT "\r\nContent-Type: application/json\r\nContent-Length: "
  mov rsi,r12
  call put_u64
  mov dword ptr [rdi],0x0a0d0a0d
  add rdi,4
  pop r12
  pop rbx
  ret

# finish rbx job, rdi end of body (body began at scratch+512), rbp ctx: moves the response into an allocation.
finish:
  push r12
  push r13
  mov r13,[rbp+PG_SCRATCH]
  add r13,512
  mov r12,rdi
  sub r12,r13            # body length
  lock add [rip+g_tx],r12
  lea rdi,[r12+256]
  call alloc
  mov [rbx+J_RESP],rax
  cmp dword ptr [rbx+J_GZ],0
  je .Lf_plain
  cmp r12,2560           # tags, the most frequent response, save little for the CPU
  jb .Lf_plain
  cmp qword ptr [rip+g_gz_on],0
  je .Lf_plain
  # compressed body at +256; the head goes right before it, built in the scratch's first 512 bytes
  mov rdi,r13
  mov rsi,r12
  lea rdx,[rax+256]
  mov rcx,r12
  call gz_compress
  test rax,rax
  jz .Lf_plain0
  push r14
  mov r14,rax
  mov rdi,[rbp+PG_SCRATCH]
  mov esi,[rbx+J_STATUS]
  mov rdx,rax
  call http_head
  sub rdi,2
  LIT "Content-Encoding: gzip\r\n\r\n"
  mov rsi,[rbp+PG_SCRATCH]
  mov rcx,rdi
  sub rcx,rsi            # head length
  mov eax,256
  sub rax,rcx
  mov [rbx+J_RESPOFF],rax
  lea rdx,[rcx+r14]
  mov [rbx+J_RESPLEN],rdx
  mov rdi,[rbx+J_RESP]
  add rdi,rax
  call mcpy
  pop r14
  pop r13
  pop r12
  ret
.Lf_plain0:
  mov rax,[rbx+J_RESP]
.Lf_plain:
  mov rdi,rax
  mov esi,[rbx+J_STATUS]
  mov rdx,r12
  call http_head
  mov rsi,r13
  mov rcx,r12
  call mcpy
  mov rax,[rbx+J_RESP]
  sub rdi,rax
  mov [rbx+J_RESPLEN],rdi
  mov qword ptr [rbx+J_RESPOFF],0
  pop r13
  pop r12
  ret

# finish_nobody: rbx job with status in esi and an error body or a 204
finish_err:           # esi status
  mov [rbx+J_STATUS],esi
  mov rdi,[rbp+PG_SCRATCH]
  add rdi,512
  LIT "{\"errors\":{\"body\":[\"request failed\"]}}"
  jmp finish
finish_204:
  mov edi,64
  call alloc
  mov [rbx+J_RESP],rax
  mov rdi,rax
  LIT "HTTP/1.1 204 No Content\r\n\r\n"
  mov rax,[rbx+J_RESP]
  sub rdi,rax
  mov [rbx+J_RESPLEN],rdi
  mov qword ptr [rbx+J_RESPOFF],0
  ret

.macro BODY
  mov rdi,[rbp+PG_SCRATCH]
  add rdi,512
.endm

# Scratch headroom: a row is at most MAX_BODY raw, 6x when escaped.
.macro ROOM fail
  mov rax,[rbp+PG_SCRATCH]
  add rax,SCRATCH_CAP-0x2000000
  cmp rdi,rax
  ja \fail
.endm

# render_user r13 job... (uses rbx=row cursor at id, r14=job): appends the whole {"user":...}
render_user:
  push r12
  call fld
  mov r12,[rsi]
  bswap r12
  LIT "{\"user\":{\"username\":"
  call r_str
  LIT ",\"email\":"
  call r_str
  LIT ",\"bio\":"
  call r_nstr
  LIT ",\"image\":"
  call r_nstr
  LIT ",\"token\":\""
  mov rsi,[r14+J_TOK]
  test rsi,rsi
  jz 1f
  mov rcx,[r14+J_TOK+8]
  call mcpy
  jmp 2f
1:push rdi
  call now_s
  mov rdx,rax
  pop rdi
  mov rsi,r12
  call jwt_make
2:mov dword ptr [rdi],0x7d7d7d22
  add rdi,3
  pop r12
  ret

# Profile object from a row: rbx at username; eax following (or -1: read a bool column after image).
render_profile:
  push r12
  mov r12d,eax
  LIT "{\"profile\":{\"username\":"
  call r_str
  LIT ",\"bio\":"
  call r_nstr
  LIT ",\"image\":"
  call r_nstr
  LIT ",\"following\":"
  cmp r12d,-1
  jne 1f
  call r_bool
  jmp 2f
1:mov eax,r12d
  call put_bool
2:mov word ptr [rdi],0x7d7d
  add rdi,2
  pop r12
  ret

# ---------------------------------------------------------------- reader thread
# build_array rdi out, rsi jobs array, rdx n, cl spec: one text-array parameter -> rdi advanced
build_array:
  push rbx
  push r12
  push r13
  push r14
  mov r12,rsi
  mov r13,rdx
  movzx r14d,cl
  lea rbx,[rdi]          # length slot
  add rdi,4
  mov byte ptr [rdi],'{'
  inc rdi
  xor ecx,ecx
  push rbx
1:cmp rcx,r13
  je 8f
  test rcx,rcx
  jz 2f
  mov byte ptr [rdi],','
  inc rdi
2:mov rax,[r12+rcx*8]
  push rcx
  cmp r14d,0x10
  jae 4f
  # integer
  mov rsi,[rax+J_VIEWER]
  cmp r14d,1
  je 3f
  mov rsi,[rax+J_A]
  cmp r14d,2
  je 3f
  mov rsi,[rax+J_B]
  cmp r14d,3
  je 3f
  mov esi,[rax+J_SUB]
3:call put_u64
  jmp 7f
4:lea rdx,[r14-0x10]
  shl rdx,4
  mov rsi,[rax+J_S0+rdx]
  mov rcx,[rax+J_S0+rdx+8]
  test rsi,rsi
  jnz 5f
  xor ecx,ecx
5:mov byte ptr [rdi],'"'
  inc rdi
  call arr_esc
  mov byte ptr [rdi],'"'
  inc rdi
7:pop rcx
  inc rcx
  jmp 1b
8:mov byte ptr [rdi],'}'
  inc rdi
  pop rbx
  mov rax,rdi
  sub rax,rbx
  sub rax,4
  bswap eax
  mov [rbx],eax
  pop r14
  pop r13
  pop r12
  pop rbx
  ret
# escape " and \ for an array element: rsi src, rcx len
arr_esc:
  test rcx,rcx
  jz 3f
1:mov al,[rsi]
  inc rsi
  cmp al,'"'
  je 2f
  cmp al,0x5c
  jne 4f
2:mov byte ptr [rdi],0x5c
  inc rdi
4:mov [rdi],al
  inc rdi
  dec rcx
  jnz 1b
3:ret

.macro BIND_TAIL
  # result format: all binary; then Execute
  mov dword ptr [rdi],0x01000100
  add rdi,4
.endm

# Close a 'B' message whose first byte is at r15; adds Execute (rdi current).
bind_close:
  mov rax,rdi
  sub rax,r15
  dec rax
  bswap eax
  mov [r15+1],eax
  mov byte ptr [rdi],'E'
  mov dword ptr [rdi+1],0x09000000
  mov byte ptr [rdi+5],0
  mov dword ptr [rdi+6],0
  add rdi,10
  ret

# exec_family rbp ctx, r12d kind, r13 n jobs (in PG_JOBS+offset r14) -> rax 1 ok, 0 error
exec_family:
  push rbx
  push r15
  mov rdi,[rbp+PG_SEND]
  mov r15,rdi
  lea rax,[rip+fam_names]
  mov rsi,[rax+r12*8]
  call bind_begin
  lea rax,[rip+fam_params]
  mov rbx,[rax+r12*8]
  # param count
  xor eax,eax
1:cmp byte ptr [rbx+rax],0
  je 2f
  inc eax
  jmp 1b
2:xchg al,ah
  mov [rdi],ax
  add rdi,2
3:movzx ecx,byte ptr [rbx]
  test ecx,ecx
  jz 4f
  mov rsi,r14
  mov rdx,r13
  call build_array
  inc rbx
  jmp 3b
4:BIND_TAIL
  call bind_close
  mov byte ptr [rdi],'S'
  mov dword ptr [rdi+1],0x04000000
  add rdi,5
  sub rdi,[rbp+PG_SEND]
  call pg_roundtrip
  pop r15
  pop rbx
  ret

# Walk 'D' messages. rax message start -> next message (rdx payload end).
.macro NEXT_MSG reg
  mov edx,[\reg+1]
  bswap edx
  lea \reg,[\reg+rdx+1]
.endm

# List row offsets: 7 header, t 4+4, a 4+8, pk length 4, then the array's ndim, flags, oid, dim, lbound.
.set PK_LEN,27
.set PK_DIM,31+12
.set PK_ELEM,31+20       # each element: 4 length, 8 value
# render_family rbp ctx, r12d kind, r13 n jobs, r14 jobs array: renders every job.
render_family:
  push rbx
  push r15
  cmp r12d,K_TAGS
  je .Lr_tags
  mov r15,[rbp+PG_RECV]
  xor ecx,ecx
  # reset per-job state
.Lr0:
  cmp rcx,r13
  je .Lr1
  mov rax,[r14+rcx*8]
  mov qword ptr [rax+J_ROW],0
  mov qword ptr [rax+J_COUNT],0
  inc rcx
  mov [rax+J_ORD],rcx
  jmp .Lr0
.Lr1:
  mov rax,[rbp+PG_RECV]
  add rax,[rbp+PG_END]
  push rax               # end of replies at [rsp]
  cmp r12d,K_FEED
  ja .Lr_ord
  # ---- list rows: index articles, find each job's first page row, take counts
.Lr2:
  cmp r15,[rsp]
  jae .Lr_lists
  cmp byte ptr [r15],'D'
  jne .Lr3
  mov eax,[r15+11]       # t
  bswap eax
  mov rcx,[r15+15+4]
  bswap rcx              # a
  mov rdx,rcx
  test eax,eax
  jnz .Lr4
  # article: remember where its slug column starts (skip t,a,pk,fa,fo,id,author); row_flags reads id and author just before it
  lea rbx,[r15+7]
  call fld
  call fld
  call fld
  call fld
  call fld
  call fld
  call fld
  mov rax,[rbp+PG_ARTS]
  mov [rax+rdx*8],rbx
  jmp .Lr3
.Lr4:
  mov rdx,[r14+rcx*8-8]
  cmp eax,1
  jne .Lr5
  cmp qword ptr [rdx+J_ROW],0
  jne .Lr3
  mov [rdx+J_ROW],r15
  jmp .Lr3
.Lr5:
  # count: the only element of pk
  mov rax,[r15+PK_ELEM+4]
  bswap rax
  mov [rdx+J_COUNT],rax
.Lr3:
  NEXT_MSG r15
  jmp .Lr2
.Lr_ord:
  # ---- rows starting with ord: first row per job
.Lo2:
  cmp r15,[rsp]
  jae .Lr_each
  cmp byte ptr [r15],'D'
  jne .Lo3
  mov rcx,[r15+11]
  bswap rcx
  mov rdx,[r14+rcx*8-8]
  cmp qword ptr [rdx+J_ROW],0
  jne .Lo3
  mov [rdx+J_ROW],r15
.Lo3:
  NEXT_MSG r15
  jmp .Lo2
.Lr_lists:
.Lr_each:
  add rsp,8
  xor r15d,r15d
.Lr6:
  cmp r15,r13
  je .Lr9
  mov rbx,[r14+r15*8]
  push r14
  mov r14,rbx
  call render_job
  pop r14
  # forwarded jobs (login -> bcrypt) return rax=1
  test eax,eax
  jnz .Lr7
  call deliver
.Lr7:
  inc r15
  jmp .Lr6
.Lr9:
  pop r15
  pop rbx
  ret
.Lr_tags:
  # all waiters get the same bytes
  mov r15,[rbp+PG_RECV]
  mov rbx,r15
  BODY
  LIT "{\"tags\":["
  mov rax,[rbp+PG_RECV]
  add rax,[rbp+PG_END]
  push rax
  xor r8d,r8d
  mov r15,rbx
1:cmp r15,[rsp]
  jae 3f
  cmp byte ptr [r15],'D'
  jne 2f
  test r8d,r8d
  jz 4f
  mov byte ptr [rdi],','
  inc rdi
4:mov ecx,[r15+7]
  bswap ecx
  lea rsi,[r15+11]
  call json_esc
  mov r8d,1
2:NEXT_MSG r15
  jmp 1b
3:add rsp,8
  mov word ptr [rdi],0x7d5d
  add rdi,2
  mov r15,rdi            # end of the shared body
  xor ebx,ebx
  push r12
  mov r12,rbx
5:cmp r12,r13
  je 6f
  mov rbx,[r14+r12*8]
  mov rdi,r15
  call finish
  call deliver
  inc r12
  jmp 5b
6:pop r12
  pop r15
  pop rbx
  ret

# render_job rbx=r14=job, r12d kind -> rax 1 when the job moved on (do not deliver)
render_job:
  cmp r12d,K_LOGIN
  je .Lj_login
  cmp r12d,K_FEED
  jbe .Lj_list
  cmp qword ptr [rbx+J_ROW],0
  je .Lj_404
  cmp r12d,K_COMMENTS
  je .Lj_comments
  cmp r12d,K_PROFILE
  je .Lj_profile
  # K_USER
  mov rax,[r14+J_ROW]
  lea rbx,[rax+7]
  call fld              # ord
  push rbx
  BODY
  pop rbx
  call render_user
  mov rbx,r14
  call finish
  xor eax,eax
  ret
.Lj_404:
  mov esi,404
  cmp r12d,K_USER
  jne 1f
  mov esi,401
1:call finish_err
  xor eax,eax
  ret
.Lj_profile:
  mov rax,[r14+J_ROW]
  lea rbx,[rax+7]
  call fld
  BODY
  mov eax,-1
  call render_profile
  mov rbx,r14
  call finish
  xor eax,eax
  ret
.Lj_comments:
  push r15
  mov r15,[r14+J_ROW]
  mov rax,[r14+J_ORD]
  push rax
  BODY
  LIT "{\"comments\":["
  xor r8d,r8d
1:cmp byte ptr [r15],'D'
  jne 9f
  mov rax,[r15+11]
  bswap rax
  cmp rax,[rsp]
  jne 9f
  lea rbx,[r15+7]
  call fld               # ord
  cmp dword ptr [rbx],-1 # no comments: the left join's NULL row
  je 9f
  ROOM .Lj_big
  test r8d,r8d
  jz 2f
  mov byte ptr [rdi],','
  inc rdi
2:LIT "{\"id\":"
  call r_int
  LIT ",\"body\":"
  call r_str
  LIT ",\"createdAt\":"
  call r_ts
  LIT ",\"updatedAt\":"
  call r_ts
  LIT ",\"author\":{\"username\":"
  call r_str
  LIT ",\"bio\":"
  call r_nstr
  LIT ",\"image\":"
  call r_nstr
  LIT ",\"following\":"
  call r_bool
  mov word ptr [rdi],0x7d7d
  add rdi,2
  mov r8d,1
  NEXT_MSG r15
  jmp 1b
9:mov word ptr [rdi],0x7d5d
  add rdi,2
  add rsp,8
  pop r15
  mov rbx,r14
  call finish
  xor eax,eax
  ret
.Lj_big:
  add rsp,8
  pop r15
  mov rbx,r14
  mov esi,500
  call finish_err
  xor eax,eax
  ret
.Lj_login:
  mov rax,[rbx+J_ROW]
  test rax,rax
  jz .Lj_401
  # keep the row across the bcrypt stage
  mov edx,[rax+1]
  bswap edx
  lea rdi,[rdx+64]
  push rax
  call alloc
  pop rsi
  mov [rbx+J_EXTRA],rax
  mov [rbx+J_ROW],rax
  mov edx,[rsi+1]
  bswap edx
  lea rcx,[rdx+1]
  mov rdi,rax
  call mcpy
  mov dword ptr [rbx+J_KIND],K_BC_VERIFY
  mov rdi,rbx
  call enqueue
  mov eax,1
  ret
.Lj_401:
  mov esi,401
  call finish_err
  xor eax,eax
  ret
.Lj_list:
  # single article by slug?
  cmp r12d,K_LIST
  jne .Lj_lst
  cmp dword ptr [rbx+J_SUB],SUB_SLUG
  jne .Lj_lst
  mov rax,[rbx+J_ROW]
  test rax,rax
  jz .Lj_404
  # page row: one article
  push r15
  mov r15,rax
  xor r8d,r8d
  call row_flags
  pop r15
  or eax,4
  push rbx
  push rax
  BODY
  LIT "{\"article\":"
  pop rax
  pop rbx
  call r_article
  mov byte ptr [rdi],'}'
  inc rdi
  mov rbx,r14
  call finish
  xor eax,eax
  ret
.Lj_lst:
  push r15
  mov r15,[r14+J_ROW]
  BODY
  LIT "{\"articles\":["
  test r15,r15
  jz 3f
  xor r8d,r8d
1:mov eax,[r15+PK_DIM]
  bswap eax
  cmp r8d,eax
  jae 3f
  ROOM .Lj_big2
  test r8,r8
  jz 2f
  mov byte ptr [rdi],','
  inc rdi
2:call row_flags
  push r8
  call r_article
  pop r8
  inc r8
  jmp 1b
3:LIT "],\"articlesCount\":"
  mov rsi,[r14+J_COUNT]
  call put_u64
  mov byte ptr [rdi],'}'
  inc rdi
  pop r15
  mov rbx,r14
  call finish
  xor eax,eax
  ret
.Lj_big2:
  pop r15
  mov rbx,r14
  mov esi,500
  call finish_err
  xor eax,eax
  ret

# row_flags r15 page row, r8 position in the page -> rbx the article's slug column, eax favorited | following<<1.
# Values compare as stored, big-endian, so nothing is swapped. Keeps rdi, r8.
row_flags:
  lea rax,[r8+r8*2]
  mov rcx,[r15+rax*4+PK_ELEM+4]
  bswap rcx
  mov rdx,[rbp+PG_ARTS]
  mov rbx,[rdx+rcx*8]
  mov edx,[r15+PK_LEN]
  bswap edx
  lea rdx,[r15+rdx+PK_LEN+4]   # fa
  mov r9,[rbx-20]              # id
  call arr_has
  mov eax,r10d
  mov r9,[rbx-8]               # author
  call arr_has
  lea eax,[rax+r10*2]
  ret
# arr_has rdx int8[] field, r9 value as stored -> r10d 1 if present, rdx next field. Keeps rax.
arr_has:
  mov ecx,[rdx]
  bswap ecx
  lea r11,[rdx+rcx+4]
  xor r10d,r10d
  cmp dword ptr [rdx+4],0      # no dimensions: empty
  je 3f
  mov ecx,[rdx+16]
  bswap ecx
  lea rsi,[rdx+28]             # first value; each element is 4 length, 8 value
1:cmp r9,[rsi]
  je 2f
  add rsi,12
  dec ecx
  jnz 1b
  jmp 3f
2:mov r10d,1
3:mov rdx,r11
  ret

# run_batch rbp ctx, r12d kind, r13 n, r14 jobs array
run_batch:
  call exec_family
  test eax,eax
  jz 1f
  # article views have their own statement but the list family's rows and renderer
  push r12
  cmp r12d,NFAM
  jb 9f
  xor r12d,r12d
9:call render_family
  pop r12
  call flush_notify
  ret
1:cmp r13,1
  ja 2f
  # one job and it failed: 500
  mov rbx,[r14]
  mov esi,500
  call finish_err
  call deliver
  call flush_notify
  ret
2:# isolate the bad job: rerun each alone
  push r13
  push r14
  push r15
  mov r15,r13
3:mov r13d,1
  call run_batch
  add r14,8
  dec r15
  jnz 3b
  pop r15
  pop r14
  pop r13
  ret

# reader_main rdi ctx
# gz_tick r15 now: twice a second one reader decides whether to compress. Worth it only while the network is the limit:
# over 100 MB/s of responses and TCP retransmits; off again below 80 MB/s, measured before compression so it cannot flap.
.set SYS_OPEN,2
gz_tick:
  cmp qword ptr [rip+g_gz_mode],2
  jne 9f
  mov rax,[rip+g_gz_next]
  cmp r15,rax
  jb 9f
  lea rcx,[r15+500]
  lock cmpxchg [rip+g_gz_next],rcx
  jne 9f
  xor eax,eax
  xchg rax,[rip+g_tx]
  mov rcx,r15
  sub rcx,[rip+g_gz_last]
  mov [rip+g_gz_last],r15
  test rcx,rcx
  jz 9f
  xor edx,edx
  div rcx                # bytes/ms = kB/s
  push rax
  sub rsp,4096
  lea rdi,[rip+gz_snmp]
  xor esi,esi
  xor edx,edx
  SYS SYS_OPEN
  mov r8,rax
  test rax,rax
  js 7f
  mov rdi,rax
  mov rsi,rsp
  mov edx,4095
  SYS SYS_READ
  mov r9,rax
  mov rdi,r8
  SYS SYS_CLOSE
  test r9,r9
  jle 7f
  # the second line starting "Tcp: " holds the values; RetransSegs is the 12th
  mov rsi,rsp
  lea r10,[rsp+r9]
  xor ecx,ecx
1:cmp rsi,r10
  jae 7f
  cmp dword ptr [rsi],0x3a706354
  jne 2f
  cmp rsi,rsp
  je 2f
  cmp byte ptr [rsi-1],10
  jne 2f
  inc ecx
  cmp ecx,2
  je 3f
2:inc rsi
  jmp 1b
3:add rsi,4
  mov ecx,12
4:cmp byte ptr [rsi],' '
  jne 5f
  inc rsi
  dec ecx
  jz 55f
5:cmp rsi,r10
  jae 7f
  cmp byte ptr [rsi],' '
  je 4b
  inc rsi
  jmp 5b
55:xor eax,eax
6:movzx edx,byte ptr [rsi]
  sub edx,'0'
  cmp edx,9
  ja 8f
  imul rax,rax,10
  add rax,rdx
  inc rsi
  jmp 6b
8:mov rcx,rax
  sub rcx,[rip+g_gz_retrans]
  mov [rip+g_gz_retrans],rax
  mov rax,[rsp+4096]     # kB/s
  cmp qword ptr [rip+g_gz_on],0
  jne 81f
  cmp rax,100000
  jb 7f
  cmp rcx,20
  jb 7f
  mov qword ptr [rip+g_gz_on],1
  jmp 7f
81:cmp rax,80000
  jae 7f
  mov qword ptr [rip+g_gz_on],0
7:add rsp,4104
9:ret
.section .rodata
gz_snmp: .asciz "/proc/net/snmp"
.text

.globl reader_main
reader_main:
  mov rbp,rdi
  call pg_connect
  lea rbx,[rip+read_stmts]
1:mov rdi,[rbx]
  test rdi,rdi
  jz 2f
  mov rsi,[rbx+8]
  call pg_prepare
  add rbx,16
  jmp 1b
2:lock inc dword ptr [rip+g_ready]
.Lread:
  call now_ms
  mov r15,rax
  call gz_tick
  lea rdi,[rip+q_lock]
  call spin_lock
  # Shortest job first, among the families that are ready: a family is ready once its oldest job has gathered for the
  # family's gather time, and a cheap family's jobs count as older than they are.
  lea r9,[rip+queues]
  xor ecx,ecx
  mov r8,-1              # best effective t0
  mov r12d,-1
  mov r10,-1             # soonest time left among those still gathering
  lea rsi,[rip+fam_bonus]
1:mov rax,[r9+Q_HEAD]
  test rax,rax
  jz 2f
  mov rax,[rax+J_T0]
  movzx edx,byte ptr [rsi+rcx]
  mov rdi,[rip+g_gather_ms]
  test edx,edx
  jz 3f
  cmp rdi,FAST_GATHER_MS
  jbe 3f
  mov edi,FAST_GATHER_MS
3:mov r11,r15
  sub r11,rax            # age
  cmp r11,rdi
  jge 4f
  sub rdi,r11
  cmp rdi,r10
  jae 2f
  mov r10,rdi
  jmp 2f
4:sub rax,rdx
  cmp rax,r8
  jae 2f
  mov r8,rax
  mov r12d,ecx
2:add r9,Q_SIZE
  inc ecx
  cmp ecx,NFAM+2
  jne 1b
  cmp r12d,-1
  jne .Lr_take
  mov rdx,r10            # -1 when every queue is empty: sleep until woken
  jmp .Lr_sleep
.Lr_sleep:
  mov esi,[rip+r_seq]
  lock inc dword ptr [rip+r_idle]
  mov dword ptr [rip+q_lock],0
  lea rdi,[rip+r_seq]
  call futex_wait
  lock dec dword ptr [rip+r_idle]
  jmp .Lread
.Lr_take:
  imul eax,r12d,Q_SIZE
  lea r9,[rip+queues]
  add r9,rax
  mov rsi,[rip+g_read_batch]
  call q_detach
  mov dword ptr [rip+q_lock],0
  mov r13,rdx
  mov r14,[rbp+PG_JOBS]
  # list -> array
  xor ecx,ecx
3:mov [r14+rcx*8],rax
  mov rax,[rax+J_NEXT]
  inc rcx
  cmp rcx,r13
  jne 3b
  call run_batch
  jmp .Lread

# ---------------------------------------------------------------- writer thread
# bind_write rdi out, rsi stmt name, rdx param spec, rcx job -> rdi advanced
bind_write:
  push rbx
  push r12
  push r15
  mov r15,rdi
  mov rbx,rdx
  mov r12,rcx
  call bind_begin
  xor eax,eax
1:cmp byte ptr [rbx+rax],0
  je 2f
  inc eax
  jmp 1b
2:xchg al,ah
  mov [rdi],ax
  add rdi,2
3:movzx ecx,byte ptr [rbx]
  test ecx,ecx
  jz 9f
  inc rbx
  cmp ecx,0x10
  jae 5f
  mov rsi,[r12+J_VIEWER]
  cmp ecx,1
  je 4f
  mov rsi,[r12+J_A]
4:push rdi
  add rdi,4
  call put_u64
  pop rax
  mov rcx,rdi
  sub rcx,rax
  sub rcx,4
  bswap ecx
  mov [rax],ecx
  jmp 3b
5:sub ecx,0x10
  shl ecx,4
  mov rsi,[r12+J_S0+rcx]
  mov rdx,[r12+J_S0+rcx+8]
  test rsi,rsi
  jnz 6f
  mov dword ptr [rdi],-1
  add rdi,4
  jmp 3b
6:mov eax,edx
  bswap eax
  mov [rdi],eax
  add rdi,4
  mov rcx,rdx
  call mcpy
  jmp 3b
9:BIND_TAIL
  call bind_close
  pop r15
  pop r12
  pop rbx
  ret

# write_group rbp ctx, r14 jobs, r13 n -> rax 1 committed. J_ROW holds each job's reply row (or 0).
write_group:
  push rbx
  push r12
  mov rdi,[rbp+PG_SEND]
  xor r12d,r12d
1:cmp r12,r13
  je 4f
  mov rcx,[r14+r12*8]
  mov qword ptr [rcx+J_ROW],0
  mov eax,[rcx+J_KIND]
  cmp eax,K_ARTNEW
  jne 2f
  cmp qword ptr [rcx+J_TAGS],0
  je 2f
  # tags go first so the article's statement sees them
  push rcx
  lea rsi,[rip+n_wt]
  lea rdx,[rip+pwt]
  call bind_write
  pop rcx
  mov eax,[rcx+J_KIND]
2:sub eax,K_REG
  shl eax,4
  lea rdx,[rip+wr_params]
  mov rsi,[rdx+rax]
  mov rdx,[rdx+rax+8]
  call bind_write
  inc r12
  jmp 1b
4:mov byte ptr [rdi],'S'
  mov dword ptr [rdi+1],0x04000000
  add rdi,5
  sub rdi,[rbp+PG_SEND]
  call pg_roundtrip
  test eax,eax
  jz .Lwg_fail
  # assign rows to jobs: each Execute ends with a CommandComplete
  mov rbx,[rbp+PG_RECV]
  xor r12d,r12d
  mov rcx,[r14]
  xor r8d,r8d            # tag statements still to skip for this job
  call wg_skip
.Lwg_scan:
  mov al,[rbx]
  cmp al,'Z'
  je .Lwg_ok
  cmp al,'D'
  jne 5f
  test r8d,r8d
  jnz 6f
  cmp qword ptr [rcx+J_ROW],0
  jne 6f
  mov [rcx+J_ROW],rbx
  jmp 6f
5:cmp al,'C'
  jne 6f
  test r8d,r8d
  jz 7f
  dec r8d
  jmp 6f
7:inc r12
  cmp r12,r13
  je .Lwg_ok
  mov rcx,[r14+r12*8]
  call wg_skip
6:NEXT_MSG rbx
  jmp .Lwg_scan
.Lwg_ok:
  mov eax,1
.Lwg_fail:
  pop r12
  pop rbx
  ret
wg_skip:              # r8d = 1 for an article with tags: its tag statement comes first
  xor r8d,r8d
  cmp dword ptr [rcx+J_KIND],K_ARTNEW
  jne 1f
  cmp qword ptr [rcx+J_TAGS],0
  je 1f
  mov r8d,1
1:ret

# write_done rbp ctx, rbx job: decide the answer. Chained reads go to the list family.
write_done:
  push r14
  mov r14,rbx
  mov eax,[rbx+J_KIND]
  mov rcx,[rbx+J_ROW]
  mov dword ptr [rbx+J_STATUS],200
  cmp eax,K_FAV
  je .Ld_fav
  cmp eax,K_UNFAV
  je .Ld_fav
  cmp eax,K_REG
  je .Ld_reg
  cmp eax,K_UPDUSER
  je .Ld_upd
  cmp eax,K_FOLLOW
  je .Ld_fol
  cmp eax,K_UNFOLLOW
  je .Ld_fol
  cmp eax,K_ARTNEW
  je .Ld_new
  cmp eax,K_ARTUPD
  je .Ld_artupd
  cmp eax,K_CMTNEW
  je .Ld_cmt
  # K_ARTDEL / K_CMTDEL: author column
  test rcx,rcx
  jz .Ld_404
  mov rax,[rcx+11]
  bswap rax
  cmp rax,[rbx+J_VIEWER]
  jne .Ld_403
  call finish_204
  jmp .Ld_deliver
.Ld_403:
  mov esi,403
  jmp .Ld_err
.Ld_404:
  mov esi,404
.Ld_err:
  call finish_err
.Ld_deliver:
  call deliver
  pop r14
  ret
.Ld_reg:
  test rcx,rcx
  jnz 1f
  mov esi,422
  jmp .Ld_err
1:mov dword ptr [rbx+J_STATUS],201
  jmp 2f
.Ld_upd:
  test rcx,rcx
  jnz 2f
  mov esi,401
  jmp .Ld_err
2:lea rbx,[rcx+7]
  BODY
  call render_user
  mov rbx,r14
  call finish
  jmp .Ld_deliver
.Ld_fol:
  test rcx,rcx
  jz .Ld_404
  xor edx,edx
  cmp eax,K_FOLLOW
  sete dl
  push rdx
  lea rbx,[rcx+7]
  BODY
  pop rax
  call render_profile
  mov rbx,r14
  call finish
  jmp .Ld_deliver
.Ld_cmt:
  test rcx,rcx
  jz .Ld_404
  mov dword ptr [rbx+J_STATUS],201
  lea rbx,[rcx+7]
  BODY
  LIT "{\"comment\":{\"id\":"
  call r_int
  LIT ",\"body\":"
  call r_str
  LIT ",\"createdAt\":"
  call r_ts
  LIT ",\"updatedAt\":"
  call r_ts
  LIT ",\"author\":{\"username\":"
  call r_str
  LIT ",\"bio\":"
  call r_nstr
  LIT ",\"image\":"
  call r_nstr
  LIT ",\"following\":false}}}"
  mov rbx,r14
  call finish
  jmp .Ld_deliver
.Ld_fav:
  test rcx,rcx
  jz .Ld_404
  jmp .Ld_chain          # J_KEY already holds the slug
.Ld_new:
  test rcx,rcx
  jz .Ld_500
  mov dword ptr [rbx+J_STATUS],201
  lea rsi,[rcx+7]
  jmp .Ld_slug
.Ld_500:
  mov esi,500
  jmp .Ld_err
.Ld_artupd:
  test rcx,rcx
  jz .Ld_404
  mov rax,[rcx+11]
  bswap rax
  cmp rax,[rbx+J_VIEWER]
  jne .Ld_403
  lea rsi,[rcx+19]
.Ld_slug:
  # the (possibly new) slug column at rsi: length, bytes
  mov ecx,[rsi]
  bswap ecx
  add rsi,4
  push rsi
  push rcx
  lea rdi,[rcx+1]
  call alloc
  mov [rbx+J_EXTRA],rax
  mov [rbx+J_KEY],rax
  pop rcx
  pop rsi
  mov [rbx+J_KEY+8],rcx
  mov rdi,rax
  call mcpy
.Ld_chain:
  mov dword ptr [rbx+J_KIND],K_LIST
  mov dword ptr [rbx+J_SUB],SUB_SLUG
  mov qword ptr [rbx+J_A],1
  mov qword ptr [rbx+J_B],0
  mov rdi,rbx
  call enqueue
  pop r14
  ret

.globl writer_main
writer_main:
  mov rbp,rdi
  call pg_connect
  lea rbx,[rip+write_stmts]
1:mov rdi,[rbx]
  test rdi,rdi
  jz 2f
  mov rsi,[rbx+8]
  call pg_prepare
  add rbx,16
  jmp 1b
2:lock inc dword ptr [rip+g_ready]
.Lw:
  lea rdi,[rip+q_lock]
  call spin_lock
  lea r9,[rip+queues+Q_WRITE*Q_SIZE]
  cmp qword ptr [r9+Q_HEAD],0
  jne .Lw_take
  mov esi,[rip+w_seq]
  lock inc dword ptr [rip+w_idle]
  mov dword ptr [rip+q_lock],0
  lea rdi,[rip+w_seq]
  mov rdx,-1
  call futex_wait
  lock dec dword ptr [rip+w_idle]
  jmp .Lw
.Lw_take:
  mov esi,128
  call q_detach
  mov dword ptr [rip+q_lock],0
  mov r13,rdx
  mov r14,[rbp+PG_JOBS]
  xor ecx,ecx
3:mov [r14+rcx*8],rax
  mov rax,[rax+J_NEXT]
  inc rcx
  cmp rcx,r13
  jne 3b
  call write_group
  test eax,eax
  jz .Lw_retry
  xor r12d,r12d
4:mov rbx,[r14+r12*8]
  call write_done
  inc r12
  cmp r12,r13
  jne 4b
  call flush_notify
  jmp .Lw
.Lw_retry:
  # something failed, so nothing committed: each write alone, in order
  mov r12,r13
  mov r15,r14
5:mov r13d,1
  mov r14,r15
  call write_group
  mov rbx,[r14]
  test eax,eax
  jz 6f
  call write_done
  jmp 8f
6:mov esi,500
  cmp dword ptr [rbp+PG_ERR],0x30353332   # "23505" begins "2350"
  jne 7f
  cmp byte ptr [rbp+PG_ERR+4],'5'
  jne 7f
  mov esi,422
7:call finish_err
  call deliver
8:add r15,8
  dec r12
  jnz 5b
  call flush_notify
  jmp .Lw

# ---------------------------------------------------------------- bcrypt threads
.set BC_LANES,6
.set BD_SIZE,64
.globl bcrypt_main
bcrypt_main:
  mov rbp,rdi
  # The first thread hashes at low priority. The others stay at normal priority and take only a full batch that has waited
  # 300 ms, so logins cannot starve; a thread that raised its nice value could not lower it again without privileges.
  mov eax,1
  lock xadd dword ptr [rip+g_bc_seq],eax
  push rax
  sub rsp,BD_SIZE*BC_LANES+128
  # SCHED_BATCH for this thread only: hashing must not preempt the threads that serve the other 99.9% of requests;
  # an event loop or database thread must stay normal, since it pays a scheduling wait on every hop of a request
  mov dword ptr [rsp],0
  xor edi,edi
  mov esi,3
  mov rdx,rsp
  SYS SYS_SCHED_SETSCHED
  cmp dword ptr [rsp+BD_SIZE*BC_LANES+128],0
  jne 90f
  xor edi,edi
  xor esi,esi
  mov rdx,[rip+g_bcrypt_nice]
  SYS SYS_SETPRIORITY
90:
.Lb:
  call now_ms
  mov r15,rax
  lea rdi,[rip+q_lock]
  call spin_lock
  lea r9,[rip+queues+Q_BC*Q_SIZE]
  mov rax,[r9+Q_HEAD]
  test rax,rax
  jz .Lb_idle
  mov rcx,r15
  sub rcx,[rax+J_T0]
  # Overloaded: a job this old would finish after its client gave up, so answer at once and spend the CPU on newer ones.
  cmp rcx,8000
  jl 93f
  mov esi,1
  call q_detach
  mov dword ptr [rip+q_lock],0
  mov rbx,rax
  mov esi,503
  call finish_err
  call deliver
  call flush_notify
  jmp .Lb
93:cmp dword ptr [rsp+BD_SIZE*BC_LANES+128],0
  je 92f
  cmp rcx,300            # the rescue thread: only for a full batch that has waited, since small runs cost more per hash
  jl .Lb_poll
  cmp qword ptr [r9+Q_CNT],BC_LANES
  jae .Lb_take
.Lb_poll:
  # It polls rather than joining the wait group, where it could absorb the one wakeup a new job sends the first thread.
  mov dword ptr [rip+q_lock],0
  lea rdi,[rip+b_poll]
  xor esi,esi
  mov edx,50
  call futex_wait
  jmp .Lb
92:cmp qword ptr [r9+Q_CNT],BC_LANES
  jae .Lb_take
  cmp rcx,150            # wait a moment for more jobs to fill the lanes
  jge .Lb_take
  mov edx,150
  sub rdx,rcx
  jmp .Lb_sleep
.Lb_idle:
  cmp dword ptr [rsp+BD_SIZE*BC_LANES+128],0
  jne .Lb_poll
  mov rdx,-1
.Lb_sleep:
  mov esi,[rip+b_seq]
  lock inc dword ptr [rip+b_idle]
  mov dword ptr [rip+q_lock],0
  lea rdi,[rip+b_seq]
  call futex_wait
  lock dec dword ptr [rip+b_idle]
  jmp .Lb
.Lb_take:
  mov esi,BC_LANES
  call q_detach
  mov dword ptr [rip+q_lock],0
  mov r13,rdx            # n
  mov r14,[rbp+PG_JOBS]
  xor r12d,r12d
1:mov [r14+r12*8],rax
  mov rbx,rax
  mov rax,[rax+J_NEXT]
  # descriptor
  mov rcx,r12
  shl rcx,6
  lea r8,[rsp+rcx]
  push rax
  mov rax,[rbx+J_PASSWORD]
  mov [r8],rax
  mov rax,[rbx+J_PASSWORD+8]
  inc rax                # include the trailing NUL
  cmp rax,72
  jbe 2f
  mov eax,72
2:mov [r8+8],rax
  cmp dword ptr [rbx+J_KIND],K_BC_VERIFY
  je 3f
  # new hash: random salt
  lea rdi,[r8+16]
  mov esi,16
  xor edx,edx
  push r8
  SYS SYS_GETRANDOM
  pop r8
  pop rax
  jmp 4f
3:# verify: salt from the stored hash (last column of the login row)
  push r8
  mov rax,[rbx+J_ROW]
  mov rdi,rbx
  mov rbx,rax
  add rbx,7
  push rdi
  call fld
  call fld
  call fld
  call fld
  call fld
  call fld
  call fld
  mov rdx,rsi
  pop rbx
  pop r8
  # rsi = stored hash, ecx = its length; "$2a$10$" + 22 salt chars + 31 hash chars
  mov [rbx+J_B],rdx
  mov [rbx+J_A],rcx
  lea rdi,[r8+16]
  add rsi,7
  mov edx,22
  lea rcx,[rip+rev_bc]
  call b64_dec
  pop rax
4:inc r12
  cmp r12,r13
  jne 1b
  mov rdi,rsp
  mov rsi,r13
  mov edx,10
  mov r8,[rbp+PG_SCRATCH]
  call bcrypt_run
  # results
  xor r12d,r12d
5:mov rbx,[r14+r12*8]
  mov rcx,r12
  shl rcx,6
  lea r8,[rsp+rcx]
  # encode the 23 hash bytes
  lea rdi,[rsp+BD_SIZE*BC_LANES]
  lea rsi,[r8+32]
  mov edx,23
  lea rcx,[rip+b64bc_a]
  push r8
  xor r8d,r8d
  call b64_enc
  pop r8
  cmp dword ptr [rbx+J_KIND],K_BC_VERIFY
  jne 7f
  # compare with the stored 31 chars
  mov rsi,[rbx+J_B]
  add rsi,29
  lea rdi,[rsp+BD_SIZE*BC_LANES]
  xor ecx,ecx
  xor edx,edx
6:mov al,[rsi+rcx]
  xor al,[rdi+rcx]
  or dl,al
  inc ecx
  cmp ecx,31
  jne 6b
  cmp qword ptr [rbx+J_A],60
  jne 61f
  test dl,dl
  jz 62f
61:mov esi,401
  call finish_err
  jmp 8f
62:mov rax,[rbx+J_ROW]
  mov r14,rbx
  lea rbx,[rax+7]
  call fld
  push rbx
  BODY
  pop rbx
  call render_user
  mov rbx,r14
  mov dword ptr [rbx+J_STATUS],200
  call finish
  mov r14,[rbp+PG_JOBS]
8:call deliver
  jmp 9f
7:# a new hash: "$2a$10$" + salt + hash, then continue as J_SUB
  lea rdi,[rbx+J_HASH]
  mov [rbx+J_PWHASH],rdi
  mov qword ptr [rbx+J_PWHASH+8],60
  mov rax,0x24303124613224      # "$2a$10$"
  mov [rdi],rax
  add rdi,7
  lea rsi,[r8+16]
  mov edx,16
  lea rcx,[rip+b64bc_a]
  push r8
  xor r8d,r8d
  call b64_enc
  pop r8
  lea rsi,[rsp+BD_SIZE*BC_LANES]
  mov ecx,31
  call mcpy
  mov eax,[rbx+J_SUB]
  mov [rbx+J_KIND],eax
  mov rdi,rbx
  call enqueue
9:inc r12
  cmp r12,r13
  jne 5b
  call flush_notify
  jmp .Lb

.bss
.globl g_ready
g_ready: .skip 8

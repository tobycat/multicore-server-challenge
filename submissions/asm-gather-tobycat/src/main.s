# Entry point: configuration, threads, listening sockets.
.include "defs.inc"
.section .rodata
e_db: .asciz "DATABASE_URL"
e_jwt:.asciz "JWT_SECRET"
e_host:.asciz "HOST"
e_port:.asciz "PORT"
e_gather:.asciz "GATHER_MS"
e_workers:.asciz "HTTP_WORKERS"
e_readers:.asciz "DB_READERS"
e_bnice:.asciz "BCRYPT_NICE"
e_rbatch:.asciz "READ_BATCH"
e_gz:.asciz "HTTP_GZIP"
e_wr:.asciz "DB_WRITERS"
e_sb:.asciz "SCHED_BATCH"
e_bc:.asciz "BCRYPT_THREADS"
m_env:.asciz "DATABASE_URL and JWT_SECRET are required"
m_listen:.asciz "cannot listen on HOST:PORT"
.bss
.balign 8
g_writers: .skip 8
.text
.globl _start
_start:
  mov rax,[rsp]
  lea rcx,[rsp+rax*8+16]
  mov [rip+g_envp],rcx
  and rsp,-16
  # SIGPIPE ignored
  sub rsp,32
  mov qword ptr [rsp],1
  xor eax,eax
  mov [rsp+8],rax
  mov [rsp+16],rax
  mov [rsp+24],rax
  mov edi,13
  mov rsi,rsp
  xor edx,edx
  mov r10d,8
  SYS SYS_RT_SIGACTION
  # open files up to the hard limit
  mov edi,7
  mov rsi,rsp
  SYS SYS_GETRLIMIT
  mov rax,[rsp+8]
  mov [rsp],rax
  mov edi,7
  mov rsi,rsp
  SYS SYS_SETRLIMIT
  add rsp,32

  lea rdi,[rip+e_db]
  call getenv
  test rax,rax
  jz .Lnoenv
  mov rdi,rax
  call pg_parse_url
  lea rdi,[rip+e_jwt]
  call getenv
  test rax,rax
  jz .Lnoenv
  mov rdi,rax
  call strlen
  mov rsi,rax
  call jwt_init
  lea rdi,[rip+e_gather]
  mov esi,2
  call env_int
  mov [rip+g_gather_ms],rax
  lea rdi,[rip+e_workers]
  mov esi,2
  call env_int
  mov r12,rax
  lea rdi,[rip+e_readers]
  mov esi,5
  call env_int
  mov r13,rax
  lea rdi,[rip+e_bc]
  mov esi,2
  call env_int
  mov r14,rax
  lea rdi,[rip+e_sb]
  mov esi,1
  call env_int
  test rax,rax
  jz 91f
  sub rsp,16
  mov dword ptr [rsp],0
  xor edi,edi
  mov esi,3
  mov rdx,rsp
  SYS SYS_SCHED_SETSCHED
  add rsp,16
91:
  lea rdi,[rip+e_wr]
  mov esi,2
  call env_int
  mov [rip+g_writers],rax
  lea rdi,[rip+e_gz]
  mov esi,2
  call env_int
  mov [rip+g_gz_mode],rax
  cmp rax,1
  sete al
  movzx eax,al
  mov [rip+g_gz_on],rax
  lea rdi,[rip+e_rbatch]
  mov esi,MAX_BATCH
  call env_int
  cmp rax,MAX_BATCH
  jbe 9f
  mov eax,MAX_BATCH
9:mov [rip+g_read_batch],rax
  lea rdi,[rip+e_bnice]
  xor esi,esi
  call env_int
  mov [rip+g_bcrypt_nice],rax

  # database threads first: the port opens only when they are ready
  xor ebx,ebx
1:cmp rbx,r13
  je 2f
  call new_ctx
  lea rdi,[rip+reader_main]
  mov rsi,rax
  call spawn
  inc rbx
  jmp 1b
2:xor ebx,ebx
21:cmp rbx,[rip+g_writers]
  je 22f
  call new_ctx
  lea rdi,[rip+writer_main]
  mov rsi,rax
  call spawn
  inc rbx
  jmp 21b
22:xor ebx,ebx
3:cmp rbx,r14
  je 4f
  call new_ctx
  lea rdi,[rip+bcrypt_main]
  mov rsi,rax
  call spawn
  inc rbx
  jmp 3b
4:mov rax,[rip+g_writers]
  add rax,r13
5:cmp [rip+g_ready],rax
  je 6f
  push rax
  sub rsp,16
  mov qword ptr [rsp],0
  mov qword ptr [rsp+8],5000000
  mov rdi,rsp
  xor esi,esi
  SYS SYS_NANOSLEEP
  add rsp,16
  pop rax
  jmp 5b
6:
  # listen address
  sub rsp,32
  mov word ptr [rsp],2
  lea rdi,[rip+e_port]
  mov esi,3000
  call env_int
  xchg al,ah
  mov [rsp+2],ax
  mov dword ptr [rsp+4],0
  lea rdi,[rip+e_host]
  call getenv
  test rax,rax
  jz 9f
  mov rsi,rax
  xor r8d,r8d
7:xor eax,eax
8:movzx ecx,byte ptr [rsi]
  sub ecx,'0'
  cmp ecx,9
  ja 10f
  imul eax,eax,10
  add eax,ecx
  inc rsi
  jmp 8b
10:mov [rsp+4+r8],al
  inc r8
  cmp byte ptr [rsi],'.'
  jne 9f
  inc rsi
  cmp r8,4
  jb 7b
9:
  # workers
  mov rax,r12
  imul rdi,rax,W_SIZE
  call alloc
  mov [rip+g_workers],rax
  mov rbp,rax
  xor ebx,ebx
.Lwk:
  cmp rbx,r12
  je .Lpark
  imul r13,rbx,W_SIZE
  add r13,rbp
  xor eax,eax
  mov [r13+W_INBOX],rax
  mov [r13+W_NOTIFIED],eax
  mov [r13+W_ID],rbx
  xor edi,edi
  mov esi,0x80000
  SYS SYS_EVENTFD2
  mov [r13+W_EVFD],eax
  mov edi,0x80000
  SYS SYS_EPOLL_CREATE1
  mov [r13+W_EPFD],eax
  # listener
  mov edi,2
  mov esi,0x80801        # STREAM|NONBLOCK|CLOEXEC
  xor edx,edx
  SYS SYS_SOCKET
  test rax,rax
  js .Lnolisten
  mov [r13+W_LISTEN],eax
  mov r14d,eax
  sub rsp,16
  mov dword ptr [rsp],1
  .irp opt,2,15          # SO_REUSEADDR, SO_REUSEPORT
  mov edi,r14d
  mov esi,1
  mov edx,\opt
  mov r10,rsp
  mov r8d,4
  SYS SYS_SETSOCKOPT
  .endr
  # TCP_NODELAY is inherited by accepted sockets
  mov edi,r14d
  mov esi,6
  mov edx,1
  mov r10,rsp
  mov r8d,4
  SYS SYS_SETSOCKOPT
  add rsp,16
  mov edi,r14d
  mov rsi,rsp
  mov edx,16
  SYS SYS_BIND
  test rax,rax
  js .Lnolisten
  mov edi,r14d
  mov esi,65535
  SYS SYS_LISTEN
  test rax,rax
  js .Lnolisten
  # register listener and eventfd
  .irp f,W_LISTEN,W_EVFD
  sub rsp,16
  mov dword ptr [rsp],1
  mov eax,[r13+\f]
  mov [rsp+4],eax
  mov dword ptr [rsp+8],0
  mov edi,[r13+W_EPFD]
  mov esi,1
  mov edx,eax
  mov r10,rsp
  SYS SYS_EPOLL_CTL
  add rsp,16
  .endr
  lea rdi,[rip+worker_main]
  mov rsi,r13
  call spawn
  inc rbx
  jmp .Lwk
.Lpark:
  sub rsp,16
  mov qword ptr [rsp],86400
  mov qword ptr [rsp+8],0
  mov rdi,rsp
  xor esi,esi
  SYS SYS_NANOSLEEP
  add rsp,16
  jmp .Lpark
.Lnoenv:
  lea rdi,[rip+m_env]
  jmp die
.Lnolisten:
  lea rdi,[rip+m_listen]
  jmp die

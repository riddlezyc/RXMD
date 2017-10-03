module fileio_funcs

contains

!----------------------------------------------------------------------------------------
subroutine OUTPUT(mcx, ffp, avs, qvt, bos, rxp, mpt, fileNameBase)
use atom_vars; use md_context; use ff_params; use mpi_vars; use rxmd_params; use bo
use qeq_vars
!----------------------------------------------------------------------------------------
implicit none

type(md_context_type),intent(inout) :: mcx
type(atom_var_type),intent(in) :: avs 
type(qeq_var_type),intent(in) :: qvt
type(bo_var_type),intent(in) :: bos
type(forcefield_params),intent(in) :: ffp
type(rxmd_param_type),intent(in) :: rxp
type(mpi_var_type),intent(in) :: mpt

character(MAXPATHLENGTH),intent(in) :: fileNameBase

if(rxp%isBinary) call WriteBIN(mcx, avs, qvt, rxp, mpt, fileNameBase)

if(rxp%isBondFile) call WriteBND(mcx, avs, bos, mpt, fileNameBase)
if(rxp%isPDB) call WritePDB(mcx, ffp, avs, mpt, fileNameBase)

return

Contains 

!--------------------------------------------------------------------------
subroutine WriteBND(mcx, avs, bos, mpt, fileNameBase)
use mpi_vars; use bo; use support_funcs
!--------------------------------------------------------------------------
implicit none

type(md_context_type),intent(inout) :: mcx
type(atom_var_type),intent(in) :: avs 
type(bo_var_type),intent(in) :: bos
type(mpi_var_type),intent(in) :: mpt 
character(MAXPATHLENGTH),intent(in) :: fileNameBase

integer :: i, ity, j, j1, jty, m
real(8) :: bndordr(MAXNEIGHBS)
integer :: igd,jgd,bndlist(0:MAXNEIGHBS)

integer (kind=MPI_OFFSET_KIND) :: offset
integer (kind=MPI_OFFSET_KIND) :: fileSize
integer :: localDataSize
integer :: fh ! file handler

integer :: BNDLineSize, baseCharPerAtom
integer,parameter :: MaxBNDLineSize=4096
character(MaxBNDLineSize) :: BNDOneLine
real(8),parameter :: BNDcutoff=0.3d0

character(len=:),allocatable :: BNDAllLines

integer :: scanbuf

integer :: ti,tj,tk, ierr
call system_clock(ti,tk)

! precompute the total # of neighbors
m=0
do i=1, mcx%NATOMS
   do j1 = 1, mcx%nbrlist(i,0)
!--- don't count if BO is less than BNDcutoff.
       if(bos%BO(0,i,j1) > BNDcutoff) then 
           m=m+1
       endif
   enddo
enddo

200 format(i12.12,1x,3f12.3,1x,2i3,20(1x,i12.12,f6.3)) 

! get local datasize based on above format and the total # of neighbors
baseCharPerAtom=12+1+3*12+1+2*3 +1 ! last 1 for newline
localDataSize=mcx%NATOMS*(baseCharPerAtom)+m*(1+12+6)

if( (baseCharPerAtom+MAXNEIGHBS*(1+12+6)) > MaxBNDLineSize) then
    print'(a,i6,2i12)', 'ERROR: MaxBNDLineSize is too small @ WriteBND', &
                    mpt%myid, baseCharPerAtom+MAXNEIGHBS*(1+12+6), MaxBNDLineSize
endif

call MPI_File_Open(mpt%mycomm,trim(fileNameBase)//".bnd", &
    MPI_MODE_WRONLY+MPI_MODE_CREATE,MPI_INFO_NULL,fh,ierr)

! offset will point the end of local write after the scan
call MPI_Scan(localDataSize,scanbuf,1,MPI_INTEGER,MPI_SUM,mpt%mycomm,ierr)

! since offset is MPI_OFFSET_KIND and localDataSize is integer, use an integer as buffer
offset=scanbuf

! nprocs-1 rank has the total data size
call MPI_Bcast(scanbuf,1,MPI_INTEGER,mpt%nprocs-1,mpt%mycomm,ierr)
fileSize=scanbuf

call MPI_File_set_size(fh, fileSize, ierr)

! set offset at the beginning of the local write
offset=offset-localDataSize

call MPI_File_Seek(fh,offset,MPI_SEEK_SET,ierr)

allocate(character(len=localDataSize) :: BNDAllLines)
BNDALLLines=""

BNDLineSize=0
do i=1, mcx%NATOMS
   ity = nint(avs%atype(i))
!--- get global ID for i-atom
   igd = l2g(avs%atype(i))

!--- count the number bonds to be shown.
   bndlist(0)=0
   do j1 = 1, mcx%nbrlist(i,0)
      j = mcx%nbrlist(i,j1)
      jty = nint(avs%atype(j))

!--- get global ID for j-atom
      jgd = l2g(avs%atype(j))

!--- if bond order is less than 0.3, ignore the bond.
      if( bos%BO(0,i,j1) < 0.3d0 ) cycle

      bndlist(0) = bndlist(0) + 1
      bndlist(bndlist(0)) = jgd
      bndordr(bndlist(0)) = bos%BO(0,i,j1)
   enddo

   BNDOneLine=""
   write(BNDOneLine,200) igd, avs%pos(i,1:3),nint(avs%atype(i)),bndlist(0), &
         (bndlist(j1),bndordr(j1),j1=1,bndlist(0))

   ! remove space and add new_line
   BNDOneLine=trim(adjustl(BNDOneLine))//NEW_LINE('A')
   BNDLineSize=BNDLineSize+len(trim(BNDOneLine))

   BNDAllLines=trim(BNDAllLines)//trim(BNDOneLine)
enddo

if(localDataSize>0) then
   call MPI_File_Write(fh,BNDAllLines,localDataSize, &
        MPI_CHARACTER,MPI_STATUS_IGNORE,ierr)
endif

deallocate(BNDAllLines) 

call MPI_BARRIER(mpt%mycomm, ierr)
call MPI_File_Close(fh,ierr)

call system_clock(tj,tk)
mcx%it_timer(20)=mcx%it_timer(20)+(tj-ti)

return
end subroutine

!--------------------------------------------------------------------------
subroutine WritePDB(mcx, ffp, avs, mpt, fileNameBase)
use ff_params;  use mpi_vars; use support_funcs
!--------------------------------------------------------------------------
implicit none

type(md_context_type),intent(inout) :: mcx
type(atom_var_type),intent(in) :: avs 
type(forcefield_params),intent(in) :: ffp
type(mpi_var_type),intent(in) :: mpt 
character(MAXPATHLENGTH),intent(in) :: fileNameBase

integer :: i, ity, igd
real(8) :: tt=0.d0, ss=0.d0

integer (kind=MPI_OFFSET_KIND) :: offset
integer (kind=MPI_OFFSET_KIND) :: fileSize
integer :: localDataSize
integer :: fh ! file handler

integer,parameter :: PDBLineSize=67
character(PDBLineSize) :: PDBOneLine

character(len=:),allocatable :: PDBAllLines

integer :: scanbuf

integer :: ti,tj,tk, ierr
call system_clock(ti,tk)

! get local datasize
localDataSize=mcx%NATOMS*PDBLineSize

call MPI_File_Open(mpt%mycomm,trim(fileNameBase)//".pdb", &
     MPI_MODE_WRONLY+MPI_MODE_CREATE,MPI_INFO_NULL,fh,ierr)

! offset will point the end of local write after the scan
call MPI_Scan(localDataSize,scanbuf,1,MPI_INTEGER,MPI_SUM,mpt%mycomm,ierr)

! since offset is MPI_OFFSET_KIND and localDataSize is integer, use an integer as buffer
offset=scanbuf

! nprocs-1 rank has the total data size
call MPI_Bcast(scanbuf,1,MPI_INTEGER,mpt%nprocs-1,mpt%mycomm,ierr)
fileSize=scanbuf

call MPI_File_set_size(fh, fileSize, ierr)

! set offset at the beginning of the local write
offset=offset-localDataSize

allocate(character(len=localDataSize) :: PDBAllLines)
PDBAllLines=""

call MPI_File_Seek(fh,offset,MPI_SEEK_SET,ierr)

do i=1, mcx%NATOMS

  ity = nint(avs%atype(i))
!--- calculate atomic temperature 
  tt = mcx%hmas(ity)*sum(avs%v(i,1:3)*avs%v(i,1:3))
  tt = tt*UTEMP*1d-2 !scale down to use two decimals in PDB format 

!--- sum up diagonal atomic stress components 
#ifdef STRESS
  ss = sum(astr(1:3,i))/3.d0
#endif
  ss = ss*USTRS

  ss = avs%q(i)*10 ! 10x atomic charge

  igd = l2g(avs%atype(i))
  write(PDBOneLine,100)'ATOM  ',0, ffp%atmname(ity), igd, avs%pos(i,1:3), tt, ss

  PDBOneLine(PDBLineSize:PDBLineSize)=NEW_LINE('A')
  PDBAllLines=trim(PDBAllLines)//trim(PDBOneLine)

enddo

if(localDataSize>0) then
    call MPI_File_Write(fh,PDBAllLines,localDataSize, &
         MPI_CHARACTER,MPI_STATUS_IGNORE,ierr)
endif

deallocate(PDBAllLines)

call MPI_BARRIER(mpt%mycomm, ierr)
call MPI_File_Close(fh,ierr)

100 format(A6,I5,1x,A2,i12,4x,3f8.3,f6.2,f6.2)

call system_clock(tj,tk)
mcx%it_timer(21)=mcx%it_timer(21)+(tj-ti)


end subroutine

end subroutine OUTPUT

!--------------------------------------------------------------------------
subroutine ReadBIN(mcx, avs, qvt, rxp, mpt, fileName)
use atom_vars; use rxmd_params; use md_context; use mpi_vars; use MemoryAllocator
use qeq_vars; use support_funcs
!--------------------------------------------------------------------------
implicit none

type(md_context_type),intent(inout) :: mcx
type(atom_var_type),intent(inout) :: avs 
type(qeq_var_type),intent(inout) :: qvt
type(rxmd_param_type),intent(in) :: rxp
type(mpi_var_type),intent(in) :: mpt

character(*),intent(in) :: fileName

integer :: i,i1

integer (kind=MPI_OFFSET_KIND) :: offset, offsettmp
integer (kind=MPI_OFFSET_KIND) :: fileSize
integer :: localDataSize, metaDataSize, scanbuf
integer :: fh ! file handler

integer :: nmeta
integer,allocatable :: idata(:)
real(8),allocatable :: dbuf(:)
real(8) :: ddata(6), d10(10)

real(8),allocatable :: rnorm(:,:)
real(8) ::  mat(3,3)
integer :: j

integer :: ti,tj,tk, ierr
call system_clock(ti,tk)

if(.not.allocated(rnorm)) allocate(rnorm(mcx%NBUFFER,3))

! Meta Data: 
!  Total Number of MPI ranks and MPI ranks in xyz (4 integers)
!  Number of resident atoms per each MPI rank (nprocs integers) 
!  current step (1 integer) + lattice parameters (6 doubles)

nmeta=4+mpt%nprocs+1
allocate(idata(nmeta))
metaDataSize = 4*nmeta + 8*6

call MPI_File_Open(mpt%mycomm,trim(fileName),MPI_MODE_RDONLY,MPI_INFO_NULL,fh,ierr)

! read metadata at the beginning of file
offsettmp=0
call MPI_File_Seek(fh,offsettmp,MPI_SEEK_SET,ierr)
call MPI_File_Read(fh,idata,nmeta,MPI_INTEGER,MPI_STATUS_IGNORE,ierr)

offsettmp=4*nmeta
call MPI_File_Seek(fh,offsettmp,MPI_SEEK_SET,ierr)
call MPI_File_Read(fh,ddata,6,MPI_DOUBLE_PRECISION,MPI_STATUS_IGNORE,ierr)

mcx%NATOMS = idata(4+mpt%myid+1)
mcx%current_step = idata(nmeta)
deallocate(idata)
mcx%lata=ddata(1); mcx%latb=ddata(2); mcx%latc=ddata(3)
mcx%lalpha=ddata(4); mcx%lbeta=ddata(5); mcx%lgamma=ddata(6)

! Get local datasize: 10 doubles for each atoms
localDataSize = 8*mcx%NATOMS*10

! offset will point the end of local write after the scan
call MPI_Scan(localDataSize,scanbuf,1,MPI_INTEGER,MPI_SUM,mpt%mycomm,ierr)

! Since offset is MPI_OFFSET_KIND and localDataSize is integer, use an integer as buffer
offset = scanbuf + metaDataSize

! nprocs-1 rank has the total data size
fileSize = offset
!call MPI_Bcast(fileSize,1,MPI_INTEGER,nprocs-1,mpt%mycomm,ierr)
!call MPI_File_set_size(fh, fileSize, ierr)

! set offset at the beginning of the local write
offset=offset-localDataSize
call MPI_File_Seek(fh,offset,MPI_SEEK_SET,ierr)

allocate(dbuf(10*mcx%NATOMS))
call MPI_File_Read(fh,dbuf,10*mcx%NATOMS,MPI_DOUBLE_PRECISION,MPI_STATUS_IGNORE,ierr)

if(.not.allocated(avs%atype)) call allocatord1d(avs%atype,1,mcx%NBUFFER)
if(.not.allocated(avs%q)) call allocatord1d(avs%q,1,mcx%NBUFFER)
if(.not.allocated(avs%pos)) call allocatord2d(avs%pos,1,mcx%NBUFFER,1,3)
if(.not.allocated(avs%v)) call allocatord2d(avs%v,1,mcx%NBUFFER,1,3)
if(.not.allocated(avs%f)) call allocatord2d(avs%f,1,mcx%NBUFFER,1,3)
if(.not.allocated(qvt%qsfp)) call allocatord1d(qvt%qsfp,1,mcx%NBUFFER)
if(.not.allocated(qvt%qsfv)) call allocatord1d(qvt%qsfv,1,mcx%NBUFFER)
avs%f(:,:)=0.0

do i=1, mcx%NATOMS
    i1=10*(i-1)
    rnorm(i,1:3)=dbuf(i1+1:i1+3)
    avs%v(i,1:3)=dbuf(i1+4:i1+6)
    avs%q(i)=dbuf(i1+7)
    avs%atype(i)=dbuf(i1+8)
    qvt%qsfp(i)=dbuf(i1+9)
    qvt%qsfv(i)=dbuf(i1+10)
enddo
deallocate(dbuf)

call MPI_BARRIER(mpt%mycomm, ierr)
call MPI_File_Close(fh,ierr)

call GetBoxParams(mat,mcx%lata,mcx%latb,mcx%latc,mcx%lalpha,mcx%lbeta,mcx%lgamma)
do i=1, 3
do j=1, 3
   mcx%HH(i,j,0)=mat(i,j)
enddo; enddo
call UpdateBoxParams(mcx, rxp)

call xs2xu(mcx,rnorm,avs%pos,mcx%NATOMS)

call system_clock(tj,tk)
mcx%it_timer(22)=mcx%it_timer(22)+(tj-ti)

return
end

!--------------------------------------------------------------------------
subroutine WriteBIN(mcx, avs, qvt, rxp, mpt, fileNameBase)
use atom_vars; use rxmd_params; use mpi_vars; use md_context
use qeq_vars; use support_funcs
!--------------------------------------------------------------------------
implicit none

type(md_context_type),intent(inout) :: mcx
type(atom_var_type),intent(in) :: avs 
type(qeq_var_type),intent(in) :: qvt
type(rxmd_param_type),intent(in) :: rxp
type(mpi_var_type),intent(in) :: mpt

character(MAXPATHLENGTH),intent(in) :: fileNameBase

integer :: i,j

integer (kind=MPI_OFFSET_KIND) :: offset, offsettmp
integer :: localDataSize, metaDataSize, scanbuf
integer :: fh ! file handler

integer :: nmeta
integer,allocatable :: ldata(:),gdata(:)
real(8) :: ddata(6)
real(8),allocatable :: dbuf(:)

real(8),allocatable :: rnorm(:,:)

integer :: ti,tj,tk, ierr
call system_clock(ti,tk)

if( .not. allocated(rnorm) ) allocate(rnorm(mcx%NBUFFER,3))

call xu2xs(mcx, avs%pos,rnorm,mcx%NATOMS)

! Meta Data: 
!  Total Number of MPI ranks and MPI ranks in xyz (4 integers)
!  Number of resident atoms per each MPI rank (nprocs integers) 
!  current step (1 integer) + lattice parameters (6 doubles)
nmeta=4+mpt%nprocs+1
metaDataSize = 4*nmeta + 8*6

! Get local datasize: 10 doubles for each atoms
localDataSize = 8*mcx%NATOMS*10

call MPI_File_Open(mpt%mycomm,trim(fileNameBase)//".bin",MPI_MODE_WRONLY+MPI_MODE_CREATE,MPI_INFO_NULL,fh,ierr)

! offset will point the end of local write after the scan
call MPI_Scan(localDataSize,scanbuf,1,MPI_INTEGER,MPI_SUM,mpt%mycomm,ierr)

! Since offset is MPI_OFFSET_KIND and localDataSize is integer, use an integer as buffer
offset = scanbuf + metaDataSize

! save metadata at the beginning of file
allocate(ldata(nmeta),gdata(nmeta))
ldata(:)=0
ldata(4+mpt%myid+1)=mcx%NATOMS
call MPI_ALLREDUCE(ldata,gdata,nmeta,MPI_INTEGER,MPI_SUM,mpt%mycomm,ierr)
gdata(1)=mpt%nprocs
gdata(2:4)=rxp%vprocs
gdata(nmeta)=mcx%nstep+mcx%current_step

ddata(1)=mcx%lata; ddata(2)=mcx%latb; ddata(3)=mcx%latc
ddata(4)=mcx%lalpha; ddata(5)=mcx%lbeta; ddata(6)=mcx%lgamma

if(mpt%myid==0) then
   offsettmp=0
   call MPI_File_Seek(fh,offsettmp,MPI_SEEK_SET,ierr)
   call MPI_File_Write(fh,gdata,nmeta,MPI_INTEGER,MPI_STATUS_IGNORE,ierr)

   offsettmp=4*nmeta
   call MPI_File_Seek(fh,offsettmp,MPI_SEEK_SET,ierr)
   call MPI_File_Write(fh,ddata,6,MPI_DOUBLE_PRECISION,MPI_STATUS_IGNORE,ierr)
endif
deallocate(ldata,gdata)

! set offset at the beginning of the local write
offset=offset-localDataSize
call MPI_File_Seek(fh,offset,MPI_SEEK_SET,ierr)

allocate(dbuf(10*mcx%NATOMS))
do i=1, mcx%NATOMS
   j = (i - 1)*10
   dbuf(j+1:j+3)=rnorm(i,1:3)
   dbuf(j+4:j+6)=avs%v(i,1:3)
   dbuf(j+7)=avs%q(i)
   dbuf(j+8)=avs%atype(i)
   dbuf(j+9)=qvt%qsfp(i)
   dbuf(j+10)=qvt%qsfv(i)
enddo
call MPI_File_Write(fh,dbuf,10*mcx%NATOMS,MPI_DOUBLE_PRECISION,MPI_STATUS_IGNORE,ierr)
deallocate(dbuf)

call MPI_BARRIER(mpt%mycomm, ierr)
call MPI_File_Close(fh,ierr)

call system_clock(tj,tk)
mcx%it_timer(23)=mcx%it_timer(23)+(tj-ti)

return
end

end module
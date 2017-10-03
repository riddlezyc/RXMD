# suffix rules
.SUFFIXES: .o .F90 .cpp .mod
.F90.o: 
	$(FC) $(OPT) $(CPP) -c $<

%.o: %.mod

SRCS := memory.F90 cg.F90 pot.F90 fileio.F90 comm.F90 init.F90 bo.F90 qeq_vars.F90 qeq.F90 param.F90 stress.F90 list.F90 support.F90 main.F90
OBJS := $(SRCS:.F90=.o)

EXE := rxmd

#compiler settings

# Intel Compiler
#FC = mpif90 -check all -traceback
#FC = mpif90 -qopenmp -O3
#FC = mpif90 

# gfortran
FC = mpif90 -fopenmp -O3 -ffast-math
#FC = mpif90 -fopenmp -O3 -ffast-math -DQEQDUMP -DRFDUMP
#FC = mpif90 -O3 -ffast-math -DQEQDUMP -DRFDUMP
#FC = mpif90 -O3 -ffast-math 
#FC = mpif90 -fcheck=all -g

# xl fortran
#FC = mpif90 -O3 -qhot -qsmp=omp
#FC = mpif90 -O3 -qhot
#FC = mpif90 -C -g

#OPT = -O3 -qhot=level=0 -qimd=auto
#LDFLAGS = -L/soft/perftools/hpctw -lmpihpm -L/soft/perftools/bgpm/lib -lbgpm 

CPP :=
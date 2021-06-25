      module interface_qmcode

      use constants  

#ifdef MPI
      use mpi
#endif

      implicit none

      ! block of global variables to be supplied by WaveT
      real(dbl) 		        :: dt			        	! time step
      character(flg) 	        :: Fmdm				        ! kind of medium
      integer(i4b)       	    :: n_ci,n_ci_read	     	! number of CIS states
      real(dbl), allocatable    :: c_i(:),e_ci(:)	    	! CIS coefficients and energies
      real(dbl), allocatable    :: mut(:,:,:)	        	! CIS transition dipoles
      real(dbl) 		        :: mol_cc(3)			    ! molecule center
      real(dbl) 		        :: fmax(3,10),omega(10)		! field amplitude and frequency
      real(dbl)                 :: tdelay(10),pshift(10)    ! time delay and phase shift
      character(flg) 	        :: Ffld				        ! shape of impulse
      character(flg)            :: Fbin                     ! binary output   
      character(flg)            :: Fopt                     ! OMP-optimized matrix/vector multiplication 
      integer(i4b) 	        :: n_out,n_f		     	! auxiliaries for output
      integer(i4b)              :: nthr                     ! number of threads
      character(1)              :: medium_res              !restart for medium 
      integer(i4b)              :: n_res                   ! frequency for restart

      contains
 
!------------------------------------------------------------------------
! @brief Set global variables for medium 
!
! @date Created: S. Pipolo
! Modified: E. Coccia 28/11/17
!------------------------------------------------------------------------ 
      subroutine set_global_tdplas(this_dt,this_mdm,this_mol_cc,this_n_ci,this_n_ci_read,this_c_i,this_e_ci,this_mut,&
				   this_fmax,this_omega,this_Ffld,this_n_out,this_n_f,this_tdelay,this_pshift,&
                   this_Fbin,this_Fopt,this_nthr,this_res,this_n_res)
!------------------------------------------------------------------------

        implicit none

        real(dbl)     , intent(in) :: this_dt				         ! time step
        character(3)  , intent(in) :: this_mdm				         ! kind of medium
        integer(i4b)  , intent(in) :: this_n_ci,this_n_ci_read		 ! number of CIS states
        real(dbl)     , intent(in) :: this_e_ci(:)	        	     ! CIS energies
        real(dbl)     , intent(in) :: this_mut(:,:,:)			     ! CIS transition dipoles
        real(dbl)     , intent(in) :: this_mol_cc(3)			     ! molecule center
        real(dbl)     , intent(in) :: this_fmax(3,10),this_omega(10) ! field amplitude and frequency
        real(dbl)     , intent(in) :: this_tdelay(10),this_pshift(10)! time delay and phase shift
        complex(cmp)  , intent(in) :: this_c_i(:)                    ! CIS coefficients
        character(3)  , intent(in) :: this_Ffld			           	 ! shape of impulse
        character(3)  , intent(in) :: this_Fbin                      ! binary output
        character(3)  , intent(in) :: this_Fopt                      ! matrix/vector multiplication 
        integer(i4b)  , intent(in) :: this_n_out,this_n_f	         ! auxiliaries for output
        integer(i4b)  , intent(in) :: this_nthr                      ! number of threads
        character(1)  , intent(in) :: this_res                      ! restart for medium 
        integer(i4b)  , intent(in) :: this_n_res                    ! frequency for restart
        dt=this_dt
        Fmdm=this_mdm
        mol_cc=this_mol_cc
        n_ci=this_n_ci
        n_ci_read=this_n_ci_read
        allocate(c_i(n_ci),e_ci(n_ci))
        allocate(mut(3,n_ci,n_ci))
        c_i=this_c_i
        e_ci=this_e_ci
        mut=this_mut
        fmax=this_fmax
        omega=this_omega
        Ffld=this_Ffld
        n_out=this_n_out
        n_f=this_n_f
        tdelay=this_tdelay
        pshift=this_pshift
        Fbin=this_Fbin
        Fopt=this_Fopt
        nthr=this_nthr
        medium_res=this_res 
        n_res=this_n_res

        return

      end subroutine set_global_tdplas

      end module interface_qmcode

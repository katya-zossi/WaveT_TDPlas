      module propagate
      use constants
      use readio
      use spectra
      use random
      use dissipation
      use scf
      use interface_tdplas
      use initialise
#ifdef OMP
      use omp_lib
#endif
#ifdef MPI
      use mpi
#endif

      implicit none

      integer(i4b)                :: ijump=0
      real(dbl),     allocatable  :: f(:,:)
      complex(cmp),  allocatable  :: c(:),c_prev(:),c_prev2(:),h_rnd(:,:), h_rnd2(:,:)
      real(dbl),     allocatable  :: h_int(:,:), h_dis(:)
      real(dbl),     allocatable  :: pjump(:)
      real(dbl)                   :: f_prev(3),f_prev2(3)
      real(dbl)                   :: mu_prev(3),mu_prev2(3),mu_prev3(3),&
                                    mu_prev4(3), mu_prev5(3)
      real(dbl),     allocatable  :: w(:), w_prev(:)
      real(dbl)                   :: eps
      logical                     :: first=.true.

! SC mu_a is the dipole moment at current step,
!    int_rad is the classical radiated power at current step
!    int_rad_int is the integral of the classical radiated power at current step
      real(dbl) :: mu_a(3),int_rad,int_rad_int
      integer(i4b) :: file_c=10,file_e=8,file_mu=9 
      save
      private
      public create_field, prop
!
      contains
!
!------------------------------------------------------------------------
! @brief Propogate C(t) using a second
! order Euler algorithm 
! 
! 
! @date Created   : 
! Modified  : E. Coccia Dec-Apr 2017
!------------------------------------------------------------------------
      subroutine prop

       implicit none
       integer(i4b)                :: i,j,k
       complex(cmp), allocatable   :: ccexp(:) !SC 31/10/17: added to store exp(-ui*e(:)*dt), used in propagation
       character(20)               :: name_e,name_c,name_d,name_mu

       ! GG: 11/03/2019
       real(dbl), allocatable      :: q_or_f(:) !< reaction field or reaction-field polarization charges
       real(dbl), allocatable      :: pot_prev(:) 

       !MR
       real :: start, finish

! OPEN FILES
       write(name_c,'(a4,i0,a4)') "c_t_",n_f,".dat"
       write(name_e,'(a4,i0,a4)') "e_t_",n_f,".dat"
       write(name_mu,'(a5,i0,a4)') "mu_t_",n_f,".dat"
       if (Fres.eq.'Yesr') then
          if (Fbin.ne.'bin') then
             open (file_c,file=name_c,status="unknown",access="append")
             open (file_e,file=name_e,status="unknown",access="append")
             open (file_mu,file=name_mu,status="unknown",access="append")
          else
             open (file_c,file=name_c,status="unknown",access="append",form="unformatted")   
             open (file_e,file=name_e,status="unknown",access="append",form="unformatted")
             open (file_mu,file=name_mu,status="unknown",access="append",form="unformatted")  
          endif
       elseif (Fres.eq.'Nonr') then
          if (Fbin.ne.'bin') then
             open (file_c,file=name_c,status="unknown")
             open (file_e,file=name_e,status="unknown")
             open (file_mu,file=name_mu,status="unknown")
          else
             open(file_c,file=name_c,status="unknown",form="unformatted")
             open(file_e,file=name_e,status="unknown",form="unformatted")
           open(file_mu,file=name_mu,status="unknown",form="unformatted")
          endif
       endif
! ALLOCATING
       allocate (c(nstates))
       allocate (c_prev(nstates))
       allocate (c_prev2(nstates))
       allocate (h_int(nstates,nstates))
       if (Fexp.eq."exp") then 
          allocate (ccexp(nstates))
          ccexp=exp(-ui*dt*energies)
          if (Fabs.eq.'abs') ccexp=ccexp*exp(-ion_rate*dt/2.d0) 
       endif
! SP 17/07/17: new flags
       if (Fdis(1:3).eq."mar".or.Fdis(1:3).eq."nma") then
          allocate(h_dis(nstates))
          if (Fdis(5:9).eq."qjump") then
             allocate (pjump(2*nf+nexc+1))
          else
             allocate (h_rnd(nstates,nstates))
             allocate (h_rnd2(nstates,nstates))
             allocate (w(3*nstates), w_prev(3*nstates))
          endif
       endif

! STEP ZERO: build interaction matrices to do a first evolution
! Different initialization in case of restart
       if (Fres.eq.'Nonr') then
          c=coeff0
          c_prev2=coeff0
          c_prev=coeff0
          f_prev2=f(:,1)
          f_prev=f(:,1)
          ! SP 18/05/20: shouldn't we initialize mu_prev* to mu at time zero?
          mu_prev=0.d0
          mu_prev2=0.d0
          mu_prev3=0.d0
          mu_prev4=0.d0
          mu_prev5=0.d0
          n_jump=0 
       elseif (Fres.eq.'Yesr') then
          c=c_i_t
          c_prev2=c_i_prev2
          c_prev=c_i_prev
          f_prev2=f(:,restart_i-1)
          f_prev=f(:,restart_i)
          mu_prev=mu_i_prev
          mu_prev2=mu_i_prev2
          mu_prev3=mu_i_prev3
          mu_prev4=mu_i_prev4
          mu_prev5=mu_i_prev5 
       endif
       h_int=zero  
       int_rad_int=0.d0
       if(Frad.eq."arl".or.Fdis.ne."nodis") &
                               call seed_random_number_sc(iseed)

       if (Fmdm.ne."vac".and.this_Finit_int.ne."qmt") then
           ! GG: 11/03/2019 begin changes
           !MR print time
           call cpu_time(start) 
           call init_medium(c_prev,mu_prev,f_prev,h_int)
           call cpu_time(finish)
           write(*,*) '("Time = ",f6.3," seconds.")',finish-start
           ! SP 18/05/20 the following should go in a init_quantumstate
           ! module together with the QM_coupling module
           if(this_Finit_int.eq.'sce') then
            if(this_Fprop.eq."dip") then
             ! reaction field                                                 |               ! reaction field
             allocate(q_or_f(3))        
             ! mixing iter 1 and 0
             call preparing_for_scf_in_wavet(this_mix_coef,f_prev,q_or_f)
            else
             allocate(pot_prev(this_nts_act))
             call do_pot_from_coeff(c_prev,pot_prev)
             ! reaction-field polarization charges                            |               ! reaction-field polarization charges
             allocate(q_or_f(this_nts_act))
             ! mixing iter 1 and 0
             call preparing_for_scf_in_wavet(this_mix_coef,pot_prev,q_or_f)
            endif
            ! compute the molecular state in equilibrium with the medium starting from an excited state in the frozen approximation
            ! onsager model ("dip") or pcm model
            call do_scf(q_or_f,c_prev)
            ! compute the molecular dipole
            call do_dip_from_coeff(c_prev,mu_prev,nstates)
            if(this_Fprop.eq."dip") then
                    call init_after_scf_in_wavet(mu_prev)
            else
                    call do_pot_from_coeff(c_prev,pot_prev)
                    call init_after_scf_in_wavet(pot_prev)
            endif
           end if
           ! GG: 11/03/2019 end changes
           if (Fres.eq.'Nonr') then
              i=1
              call prop_medium(i,c_prev,mu_prev,f_prev,h_int)
           endif
       endif
       if (Fres.eq.'Nonr') then
          call do_mu(c,mu_prev,mu_prev2,mu_prev3,mu_prev4,mu_prev5)
          call add_int_vac(f_prev,h_int)
! SP 16/07/17: added call to output at step 0 to have full output in outfiles
          if (Fbin.ne.'bin') call out_header
          call output(1,c,f_prev,h_int)
       elseif (Fres.eq.'Yesr') then
          if (Fdis.ne."nodis") call random_seq(restart_i)
       endif

! EC 20/12/16
! Dissipation according to the Markovian SSE (eq 25 J. Phys: Condens.
! Matter vol. 24 (2012) 273201)
! OR
! Dissipation according to the non-Markovian SSE (eq 24 J. Phys:
! Condens. Matter vol. 24 (2012) 273201) 
! Add a random fluctuation for the stochastic propagation (.not.qjump)
       if (Fdis(1:3).eq."mar".or.Fdis(1:3).eq."nma") then
          call define_h_dis(h_dis,nstates)
          if (Fdis(5:9).ne."qjump") then 
             call rnd_noise(w,w_prev,nstates,first)
             first=.false.
             call add_h_rnd(h_rnd,nstates,w,w_prev) 
             call add_h_rnd2(h_rnd2,nstates)
          endif
       endif
       if (n_step.gt.1) then
         if (Fexp.eq.'exp') then
! Energy term is propagated analytically
! Interaction term via second-order Euler
           call exp_euler_prop(ccexp,nstates)
         elseif (Fexp.eq.'non') then
! Both energy and intercation terms are
! porpagated via second-order Euler
           call full_euler_prop(nstates)
         endif
       endif

! DEALLOCATION AND CLOSING
       deallocate(c,c_prev,c_prev2,h_int)
       if (Fres.eq."Yesr") deallocate(c_i_prev,c_i_t,c_i_prev2)
       if (Fexp.eq."exp") deallocate(ccexp)
       if (Fdis(1:3).eq."mar".or.Fdis(1:3).eq."nma") then

          !call deallocate_dis()
          !deallocate(h_dis)

          if (Fdis(5:9).ne."qjump") then
             deallocate(h_rnd)
             deallocate(h_rnd2)
             deallocate(w)
             deallocate(w_prev)
          endif 

#ifndef MPI
          if (Fdis(5:9).eq."qjump") then
             write(*,*)
             write(*,*) 'Total number of quantum jumps',i_sp+i_nr+i_de,&
                        '(',  real(i_sp+i_nr+i_de)/real(n_step),')'
             write(*,*) 'Spontaneous emission quantum jumps', i_sp,    &
                        '(',  real(i_sp)/real(n_step),')'
             write(*,*) 'Nonradiative relaxation quantum jumps', i_nr, &
                        '(', real(i_nr)/real(n_step),')'
             write(*,*) 'Dephasing relaxation quantum jumps', i_de,    &
                        '(', real(i_de)/real(n_step),')'
             write(*,*)
          endif
#endif
       endif

       close (file_c)
       close (file_e)
       close (file_mu)

       if(Fmdm.ne.'vac') call finalize_medium

       return

      end subroutine prop
!
!------------------------------------------------------------------------
! @brief Create electric field 
! 
! 
! @date Created   : 
! Modified  : E. Coccia 16 Jan 2018
!------------------------------------------------------------------------
      subroutine create_field 

       implicit none

       integer(i4b) :: i,j,i_max,n_tot
       real(dbl) :: t_a,ti,tf,arg
       character(15) :: name_f

       if (Fres.eq.'Nonr') then
          n_tot=n_step
       elseif (Fres.eq.'Yesr') then
          if (Fsim.eq.'y') then
             n_tot=diff_step+restart_i
          elseif (Fsim.eq.'n') then 
             n_tot=n_step+restart_i
          endif
       endif

       allocate (f(3,n_tot))
#ifndef MPI
       myrank=0
       write(name_f,'(a5,i0,a4)') "field",n_f,".dat"
       if (Fbin.ne.'bin') then
          open (7,file=name_f,status="unknown")
       else
          open (7,file=name_f,status="unknown",form="unformatted")
       endif  
#endif
#ifdef MPI
       if (myrank.eq.0) then
          write(name_f,'(a9)') "field.dat"
          if (Fbin.ne.'bin') then
             open (7,file=name_f,status="unknown")
          else
             open (7,file=name_f,status="unknown",form="unformatted")
          endif
       endif
#endif

        f(:,:)=0.d0
        select case (Ffld)
        case ("mdg")
        ! Gaussian modulated sinusoid: exp(-(t-t0)^2/s^2) * sin(wt) 
           do i=1,n_tot
              t_a=dt*(i-1)
              f(:,i) = fmax(:,1)*exp(-pt5*(t_a-t_mid)**2/(sigma(1)**2))* & 
                       sin(omega(1)*t_a)
              do j=2,npulse
                 f(:,i) = f(:,i) + fmax(:,j)*                   &
                        exp(-pt5*(t_a-(t_mid+sum(tdelay(1:j-1))))**2/(sigma(j)**2))*   &
                        sin(omega(j)*t_a+sum(pshift(1:j-1)))
              enddo 
           enddo
        case ("mds")
        ! Cosine^2 modulated sinusoid: 1/2* cos^2(pi(t-t0)/(2t0)) * sin(wt) 
        !          f=0 for t>t0
         i_max=int(t_mid/dt)
         if (2*i_max.gt.n_tot) then
            write(*,*) 'ERROR: 2*t_mid/dt must be smaller than', n_tot
#ifdef MPI
            call mpi_finalize(ierr_mpi)  
#endif
            stop
         endif
         do i=1,2*i_max
            t_a=dt*(dble(i)-1)
            f(:,i)=fmax(:,1)*cos(pi*(t_a-t_mid)/(2*t_mid))**2* &
                   sin(omega(1)*t_a)
         enddo
         do i=2*i_max+1,n_tot
            t_a=dt*(i-1)
            f(:,i)=0.
         enddo
         !do j=2,npulse
         !   i_max=int((t_mid+sum(tdelay(1:j-1)))/dt)
         !   do i=1,2*i_max
         !      t_a=dt*(dble(i)-1)
         !      f(:,i)=f(:,i)+fmax(:,j)*cos(pi*(t_a-(t_mid+sum(tdelay(1:j-1))))/ &
         !             (2.d0*(t_mid+sum(tdelay(1:j-1)))))**2/2.d0* &
         !             sin(omega(j)*t_a+sum(pshift(1:j-1)))
         !   enddo
         !   do i=2*i_max+1,n_tot
         !      t_a=dt*(i-1)
         !      f(:,i)=0.
         !   enddo
         !enddo
        case ("pip")
        ! Pi pulse: cos^2(pi(t-t0)/(2s)) * cos(w(t-t0)) 
         do i=1,n_tot
            t_a=dt*(dble(i)-1)
            f(:,i)=0.d0
            if (abs(t_a-t_mid).lt.sigma(1)) then
               f(:,i)=fmax(:,1)*(cos(pi*(t_a-t_mid)/(2*sigma(1))))**2* &
               cos(omega(1)*(t_a-t_mid))
            endif
         enddo
         do j=2,npulse
            do i=1,n_tot
               t_a=dt*(dble(i)-1)
               if (abs(t_a-(t_mid+sum(tdelay(1:j-1)))).lt.sigma(j)) then
                  f(:,i)=f(:,i)+fmax(:,j)*(cos(pi*(t_a-(t_mid+sum(tdelay(1:j-1))))/ &
                  (2*sigma(j))))**2* &
                  cos(omega(j)*(t_a-(t_mid+sum(tdelay(1:j-1))))+sum(pshift(1:j-1)))
               endif
            enddo
         enddo
        case ("sin")
        ! Sinusoid:  sin(wt) 
         do i=1,n_tot
            t_a=dt*(dble(i)-1)
            f(:,i)=fmax(:,1)*sin(omega(1)*t_a)
         enddo
         
        case ("snd")
        ! Linearly modulated (up to t0) Sinusoid:
        !         0 < t < t0 : t/to* sin(wt) 
        !             t > t0 :       sin(wt) 
         do i=1,n_tot
            t_a=dt*(dble(i)-1)
            if (t_a.gt.t_mid) then
               f(:,i)=fmax(:,1)*sin(omega(1)*t_a)
            else
               if (t_a.gt.zero) f(:,i)=fmax(:,1)*t_a/t_mid*sin(omega(1)*t_a)
            endif            
         enddo
        case ("gau")
        ! Gaussian pulse: exp(-(t-t0)^2/s^2) 
           do i=1,n_tot
              t_a=dt*(i-1)
              f(:,i)=fmax(:,1)*exp(-pt5*(t_a-t_mid)**2/(sigma(1)**2))
              do j=2,npulse
                 f(:,i)=f(:,i) + fmax(:,j)*exp(-pt5*(t_a- &
                 (t_mid+sum(tdelay(1:j-1))))**2/(sigma(j)**2)) 
              enddo
           enddo
! SP 270817: the following (commented) is probably needed for spectra  
         !do i=1,n_tot
         ! t_a=dt*(dble(i)-1)
         ! arg=-pt5*(t_a-t_mid)**2/(sigma**2)
         ! if(arg.lt.-50.d0) then 
         !   f(:,i)=zero
         ! else
         !   f(:,i)=fmax(:)*exp(arg)
         ! endif
         !enddo
        case ("css")
        ! Cos^2 pulse (only half a period): cos^2(pi*(t-t0)/(s)) 
         ti=t_mid-sigma(1)/two
         tf=t_mid+sigma(1)/two
         do i=1,n_tot
          t_a=dt*(dble(i)-1)
          f(:,i)=zero
          if (t_a.gt.ti.and.t_a.le.tf) then
            f(:,i)=fmax(:,1)*(cos(pi*(t_a-t_mid)/(sigma(1))))**2
          endif
         enddo
        case ("sta")
         ! static field
          do i=1,n_tot
           f(:,i)=fmax(:,1)
          enddo
        case default
         write(*,*)  "Error: wrong field type !"
#ifdef MPI
         call mpi_finalize(ierr_mpi)
#endif
         stop
        end select
        if (myrank.eq.0) then
        ! write out field 
           if (Fbin.ne.'bin') then
              do i=1,n_tot
                 t_a=dt*(i-1)
                 if (mod(i,n_out).eq.0) &
                     write (7,'(f12.2,3e22.10e3)') t_a,f(:,i)
              enddo
           else
              do i=1,n_tot
                 t_a=dt*(i-1)
                 if (mod(i,n_out).eq.0) write (7) t_a,f(:,i)
              enddo
           endif 
        endif
       

        close(7)
 
        return

      end subroutine create_field

!
!------------------------------------------------------------------------
! @brief Compute C^T mu C and save previous dipoles 
!
! @date Created   : 
! Modified  : E. Coccia 20/11/2017
!------------------------------------------------------------------------
      subroutine do_mu(c,mu_prev,mu_prev2,mu_prev3,mu_prev4,mu_prev5)

       implicit none

       complex(cmp), intent(IN) :: c(nstates)
       real(dbl)                :: mu_prev(3),mu_prev2(3),mu_prev3(3),mu_prev4(3), &
                                   mu_prev5(3)
       complex(cmp)             :: ctmp(nstates)
       integer(i4b)             :: j,k

#ifdef OMP
       if (Fopt.eq.'omp') then
          ctmp=0.d0
!$OMP PARALLEL REDUCTION(+:ctmp) 
!$OMP DO
          do k=1,nstates
             do j=1,nstates
                ctmp(k)=ctmp(k)+ trans_dipoles(1,k,j)*c(j)
             enddo
          enddo
!$OMP END PARALLEL
          mu_a(1)=dot_product(c,ctmp)

          ctmp=0.d0
!$OMP PARALLEL REDUCTION(+:ctmp) 
!$OMP DO
          do k=1,nstates
             do j=1,nstates
                ctmp(k)=ctmp(k)+ trans_dipoles(2,k,j)*c(j)
             enddo
          enddo
!$OMP END PARALLEL
          mu_a(2)=dot_product(c,ctmp)

          ctmp=0.d0
!$OMP PARALLEL REDUCTION(+:ctmp) 
!$OMP DO
          do k=1,nstates
             do j=1,nstates
                ctmp(k)=ctmp(k)+ trans_dipoles(3,k,j)*c(j)
             enddo
          enddo
!$OMP END PARALLEL
          mu_a(3)=dot_product(c,ctmp)
       else
          mu_a(1)=dot_product(c,matmul(trans_dipoles(1,:,:),c))
          mu_a(2)=dot_product(c,matmul(trans_dipoles(2,:,:),c))
          mu_a(3)=dot_product(c,matmul(trans_dipoles(3,:,:),c))
       endif
#endif
#ifndef OMP
       mu_a(1)=dot_product(c,matmul(trans_dipoles(1,:,:),c))
       mu_a(2)=dot_product(c,matmul(trans_dipoles(2,:,:),c))
       mu_a(3)=dot_product(c,matmul(trans_dipoles(3,:,:),c))
#endif
! SC save previous mu for radiative damping
       mu_prev5=mu_prev4
       mu_prev4=mu_prev3
       mu_prev3=mu_prev2
       mu_prev2=mu_prev
       mu_prev=mu_a

       return
 
      end subroutine do_mu

!------------------------------------------------------------------------
! @brief Write output files 
!
! @date Created   : 
! Modified  : E. Coccia 20/11/2017
!------------------------------------------------------------------------
      subroutine output(i,c,f_prev,h_int)

       implicit none

       integer(i4b),    intent(IN) :: i
       complex(cmp),    intent(IN) :: c(nstates)
       real(dbl),       intent(IN) :: h_int(nstates,nstates)
       real(dbl),       intent(IN) :: f_prev(3)
       real(dbl)                   :: e_a,e_vac,t,g_neq_t,g_neq2_t,g_eq_t,f_med(3)
       character(4000)             :: fmt_ci
       integer(i4b)                :: itmp,j,k
       complex(cmp)                :: ctmp(nstates)

       t=(i-1)*dt 
#ifdef OMP
       if (Fopt.eq.'omp') then
          ctmp=0.d0
!$OMP PARALLEL REDUCTION(+:ctmp) 
!$OMP DO
          do k=1,nstates
             do j=1,nstates
                ctmp(k)=ctmp(k)+ h_int(k,j)*c(j)
             enddo
          enddo
!$OMP END PARALLEL
          e_a=dot_product(c,energies*c+ctmp)
       else      
          e_a=dot_product(c,energies*c+matmul(h_int,c))
       endif
#endif

#ifndef OMP
       e_a=dot_product(c,energies*c+matmul(h_int,c))
#endif

! SC 07/02/16: added printing of g_neq, g_eq 
       if(Fmdm.ne.'vac') then 
          g_eq_t=e_a
          g_neq_t=e_a
          g_neq2_t=e_a
          e_vac=e_a
          call get_energies(e_vac,g_eq_t,g_neq_t,g_neq2_t)
          if (Fbin.ne.'bin') then
             write (file_e,'(i8,f14.4,7e20.8)') i,t,e_a,e_vac, &
                   g_eq_t,g_neq2_t,g_neq_t,int_rad,int_rad_int
          else
             write (file_e) i,t,e_a,e_vac, &
                   g_eq_t,g_neq2_t,g_neq_t,int_rad,int_rad_int
          endif
       else
          if (Fbin.ne.'bin') then
             write (file_e,'(i8,f14.4,3e22.10)') i,t,e_a,int_rad,int_rad_int
          else
             write (file_e) i,t,e_a,int_rad,int_rad_int
          endif 
       endif

       if (Fbin.ne.'bin') then
          write (fmt_ci,'("(i8,f14.4,",I0,"e17.8E3)")') 2*nstates
          write (file_c,fmt_ci) i,t,c(:)
          write (file_mu,'(i8,f14.4,3e22.10)') i,t,mu_a(:)
       else
          write (file_c) i,t,c(:)
          write (file_mu) i,t,mu_a(:)
       endif

       j=int(dble(i)/dble(n_out))
       if(j.lt.1) j=1
       Sdip(:,1,j)=mu_a(:)
! SP 270817: using get_* functions to communicate with TDPlas
       if(Fmdm.ne."vac".and.this_Finit_int.ne."qmt") call get_medium_dip(Sdip(:,2,j))
       Sfld(:,j)=f(:,i)

       return

      end subroutine output


!------------------------------------------------------------------------
! @brief Create the field term of the hamiltonian 
!
! @date Created   : 
! Modified  : E. Coccia 22/11/2017
!------------------------------------------------------------------------
      subroutine add_int_vac(f_prev,h_int)

       implicit none

       real(dbl), intent(IN)    :: f_prev(3)
       real(dbl), intent(INOUT) :: h_int(nstates,nstates)

       integer(i4b)             :: i,j

! SC 16/02/2016: changed to - sign, 

       h_int(:,:)=h_int(:,:)-trans_dipoles(1,:,:)*f_prev(1)-             &
                 trans_dipoles(2,:,:)*f_prev(2)-trans_dipoles(3,:,:)*f_prev(3)

       return
 
      end subroutine add_int_vac

!------------------------------------------------------------------------
! @brief Calculate the Aharonov Lorentz radiative damping 
!
! @date Created   : S. Corni 
! Modified  : E. Coccia 22/11/2017
!------------------------------------------------------------------------
      subroutine add_int_rad(mu_prev,mu_prev2,mu_prev3,mu_prev4, &
                                                   mu_prev5,h_int)

       implicit none

       integer(i4b)                :: i,j
       real(dbl),    intent(in)    :: mu_prev(3),mu_prev2(3),mu_prev3(3), &
                 mu_prev4(3), mu_prev5(3)
       real(dbl),    intent(INOUT) :: h_int(nstates,nstates)
       real(dbl)                   :: d3_mu(3),d2_mu(3),d_mu(3),d2_mod_mu,coeff,scoeff, &
                  force(3),de


!       d3_mu=(mu_prev-3.*mu_prev2+3.*mu_prev3-mu_prev4)/(dt*dt*dt)
       d3_mu=(2.5*mu_prev-9.*mu_prev2+12.*mu_prev3-7.*mu_prev4+ &
              1.5*mu_prev5)/(dt*dt*dt)
! SC 08/06/2016: i'm confused on the right formula for istantaneous radiated intensity:
!  Novotny-Hecht is pro. to (d^2/dt^2 |mu|)^2 (eq. 8.70), however in Jackson
! for Larmor one has pro. to (d^2/dt^2 mu \cdot d^2/dt^2 mu). Since Novotny-Hech
! in eq. 8.82 seems to use jacson definition, I also use it here
!       d2_mod_mu=(2.*sqrt(dot_product(mu_prev,mu_prev)) &
!                  -5.*sqrt(dot_product(mu_prev2,mu_prev2))+ &
!                  4.*sqrt(dot_product(mu_prev3,mu_prev3)) &
!               -sqrt(dot_product(mu_prev4,mu_prev4)))/(dt*dt)
       d2_mu=(2.*mu_prev-5.*mu_prev2+4.*mu_prev3-mu_prev4)/(dt*dt)
       d_mu=(1.5*mu_prev-2.*mu_prev2+0.5*mu_prev3)/dt
!SC coefficient 1/(6 pi eps0 c^3) in atomic units
       coeff=2.d0/3.d0/137.036**3.
       scoeff=coeff
!SC: added random force             
!       d3_mu=d3_mu*coeff
       force(1)=random_normal()*scoeff
       force(2)=random_normal()*scoeff
       force(3)=random_normal()*scoeff
       d3_mu=d3_mu*coeff
       de=dot_product(d_mu,force)
       if(de.lt.0) d3_mu=d3_mu+force
!       write (6,*) d3_mu
!SC Instantenous emitted intensity (from Novotny Hech eq. 8.70)
!       int_rad=coeff*d2_mod_mu*d2_mod_mu
       int_rad=coeff*dot_product(d2_mu,d2_mu)+de/dt
       int_rad_int=int_rad_int+int_rad*dt

       h_int(:,:)=h_int(:,:)-trans_dipoles(1,:,:)*d3_mu(1)-             &
                 trans_dipoles(2,:,:)*d3_mu(2)-trans_dipoles(3,:,:)*d3_mu(3)

       return

      end subroutine add_int_rad

!------------------------------------------------------------------------
! @brief Write headers to output files 
!
! @date Created   : S. Corni 
! Modified  : E. Coccia 22/11/2017
!------------------------------------------------------------------------
      subroutine out_header

       implicit none

       write(file_c,'(2a)')'# istep   time (au)', &
                           '    Re(C_0) Im(C_0), Re(C_1) Im(C_1),...'

       write(file_e,'(8a)') '#   istep time (au)',' <H(t)>-E_gs(0)', &
              ' DE_vac(t)',' DG_eq(t)',' DG_neq(t)',  '  Const', &
              '  Rad. Int', '  Rad. Ene'   
      
       write(file_mu,'(5a)') '#   istep time (au)',' dipole-x ', &
              ' dipole-y ',' dipole-z '

       return
    
      end subroutine out_header


!------------------------------------------------------------------------
! @brief Energy term is propagated analytically
! Interaction term via second-order Euler 
! 
! @date Created   : E. Coccia 15 Nov 2017
! Modified  :
!------------------------------------------------------------------------
      subroutine exp_euler_prop(ccexp,nci)

        implicit none

        integer(i4b),  intent(in)  :: nci
        complex(cmp),  intent(in)  :: ccexp(nci) 

        integer(i4b)               :: i,j,istart,iend,k
        real(dbl)                  :: t 
        complex(cmp)               :: dis(nci),ctmp(nci)

! Initialization only without restart
       if (Fres.eq.'Nonr') then
! INITIAL STEP: dpsi/dt=(psi(2)-psi(1))/dt
! SC: 31/10/17 modified the propagation with ccexp 
          c=ccexp*(c_prev-ui*dt*matmul(h_int,c_prev))
          if (Fdis.eq."ernd") then
             do j=1,nstates
                c(j) = c(j) - ccexp(j)*ui*dt*krnd*random_normal()*c_prev(j)
             enddo
          endif
          if (Fdis(1:3).eq."mar".or.Fdis(1:3).eq."nma") then
             dis=disp(h_dis,c_prev,nci)
             c=c-ccexp*dt*dis
             if (Fdis(5:9).eq."EuMar") then
          ! Euler-Maruyama
                c=c-ccexp*(ui*sqrt(dt)*matmul(h_rnd,c_prev)-dt*matmul(h_rnd2,c_prev))               
             elseif (Fdis(5:9).eq."LeiMa") then
          ! Leimkuhler-Matthews
                c=c-ccexp*(ui*0.5d0*sqrt(dt)*matmul(h_rnd,c_prev)-dt*matmul(h_rnd2,c_prev))
             endif
          endif
          c=c/sqrt(dot_product(c,c))
          c_prev=c

! SP 16/07/17: added call to medium propagation at step 2 to have full output
          f_prev=f(:,2)
          h_int=zero
          if (Fmdm.ne."vac".and.this_Finit_int.ne."qmt") then
             i=2
             call prop_medium(i,c_prev,mu_prev,f_prev,h_int)
          endif
          call add_int_vac(f_prev,h_int)
          call do_mu(c,mu_prev,mu_prev2,mu_prev3,mu_prev4,mu_prev5)
          if (mod(2,n_out).eq.0) call output(2,c,f_prev,h_int)
       endif

       if (Fres.eq.'Nonr') then
          istart=3
          iend=n_step
       elseif (Fres.eq.'Yesr') then
          istart=restart_i+1
          call add_int_vac(f_prev,h_int)
          if (Fsim.eq.'y') then 
             iend=diff_step+restart_i
          elseif (Fsim.eq.'n') then
             iend=n_step+istart-1
          endif
       endif

! PROPAGATION CYCLE: starts the propagation at timestep 3
! without restart, at timestep restart_i+1 otherwise
! Markovian dissipation (quantum jump) 
       if (Fdis(5:9).eq."qjump") then
          !do i=3,n_step
          do i=istart,iend 
! Quantum jump (spontaneous or nonradiative relaxation, pure dephasing)
! Algorithm from J. Opt. Soc. Am. B. vol. 10 (1993) 524
            dis=disp(h_dis,c_prev,nci)
#ifndef OMP
            if (i.eq.ijump+1) then
               c=ccexp*(c_prev-ui*dt*matmul(h_int,c_prev)-dt*dis)
            else 
               c=ccexp*(ccexp*c_prev2-2.d0*ui*dt*matmul(h_int,c_prev)-2.d0*dt*dis)
            endif 
#endif
#ifdef OMP
            if (Fopt.eq.'omp') then
               ctmp=0.d0
!$OMP PARALLEL REDUCTION(+:ctmp) 
!$OMP DO
               do k=1,nci
                  do j=1,nci
                     ctmp(k)=ctmp(k)+ h_int(k,j)*c_prev(j)
                  enddo
               enddo
!$OMP END PARALLEL
               if (i.eq.ijump+1) then
                  c=ccexp*(c_prev-ui*dt*ctmp-dt*dis)
               else
                  c=ccexp*(ccexp*c_prev2-2.d0*ui*dt*ctmp-2.d0*dt*dis)
               endif
            else
               if (i.eq.ijump+1) then
                  c=ccexp*(c_prev-ui*dt*matmul(h_int,c_prev)-dt*dis)
               else
                  c=ccexp*(ccexp*c_prev2-2.d0*ui*dt*matmul(h_int,c_prev)-2.d0*dt*dis)
               endif
            endif
#endif
! loss_norm computes: 
! norm = 1 - dtot
! dtot = dsp + dnr + dde
! Loss of the norm, dissipative events simulated
! eps -> uniform random number in [0,1]
            call loss_norm(c_prev,nstates,pjump)
            call random_number(eps)  
            if (dtot.gt.eps)  then
               call quan_jump(c,c_prev,nstates,pjump)
               ijump=i
               n_jump=n_jump+1
#ifndef MPI
              if (Fwrt.eq.'yes') write(*,*) 'Quantum jump at step:', i, (i-1)*dt 
#endif 
               c_prev=c
            else
                c=c/sqrt(dot_product(c,c))
                c_prev2=c_prev
                c_prev=c
            endif

            f_prev=f(:,i)
            h_int=zero
            if (Fmdm.ne."vac".and.this_Finit_int.ne."qmt") call prop_medium(i,c_prev,mu_prev,f_prev,h_int)
            call add_int_vac(f_prev,h_int)
            if (Frad.eq."arl".and.i.gt.5) call add_int_rad(mu_prev,mu_prev2,mu_prev3, & 
                                               mu_prev4,mu_prev5,h_int)
            call do_mu(c,mu_prev,mu_prev2,mu_prev3,mu_prev4,mu_prev5)
            if (mod(i,n_out).eq.0) call output(i,c,f_prev,h_int)
            ! Restart
            if (mod(i,n_restart).eq.0) then
               t=(i-1)*dt
               call wrt_restart(i,t,c,c_prev,c_prev2,nstates,iseed,mu_prev,mu_prev2,mu_prev3,mu_prev4,mu_prev5,iend)
            endif
          enddo
! Markovian dissipation (Euler-Maruyama) 
       elseif (Fdis(1:3).eq."mar") then
          !do i=3,n_step
          do i=istart,iend
! Dissipation by a continuous stochastic propagation
            call rnd_noise(w,w_prev,nstates,first)
            call add_h_rnd(h_rnd,nstates,w,w_prev)
            dis=disp(h_dis,c_prev,nci)
            if (Fdis(5:9).eq."EuMar") then
            ! Euler-Maruyama 
                c=ccexp*(c_prev-ui*dt*matmul(h_int,c_prev)-dt* &
                dis-ui*sqrt(dt)*matmul(h_rnd,c_prev)- &
                dt*matmul(h_rnd2,c_prev))
            elseif (Fdis(5:9).eq."LeiMa") then
                c=ccexp*(c_prev-ui*dt*matmul(h_int,c_prev)-dt* &
                dis-ui*0.5d0*sqrt(dt)* &
                matmul(h_rnd,c_prev)-dt*matmul(h_rnd2,c_prev))
            endif
            !c=c/sqrt(dot_product(c,c))
            c_prev=c

            f_prev=f(:,i)
            h_int=zero
            if (Fmdm.ne."vac".and.this_Finit_int.ne."qmt") call prop_medium(i,c_prev,mu_prev,f_prev,h_int)
            call add_int_vac(f_prev,h_int)
            if (Frad.eq."arl".and.i.gt.5) call add_int_rad(mu_prev,mu_prev2,mu_prev3, &
                                                  mu_prev4,mu_prev5,h_int)
            call do_mu(c,mu_prev,mu_prev2,mu_prev3,mu_prev4,mu_prev5)
            if (mod(i,n_out).eq.0) call output(i,c,f_prev,h_int)
            ! Restart
            if (mod(i,n_restart).eq.0) then
               t=(i-1)*dt
               call wrt_restart(i,t,c,c_prev,c_prev2,nstates,iseed,mu_prev,mu_prev2,mu_prev3,mu_prev4,mu_prev5,iend) 
            endif
          enddo
       elseif (Fdis.eq."nodis".or.Fdis.eq."ernd") then
! No dissipation in the propagation 
          !do i=3,n_step
          do i=istart,iend
! SC 31/10/17: modified propagation by adding the exp term
#ifndef OMP
            c=ccexp*(ccexp*c_prev2-2.d0*ui*dt*matmul(h_int,c_prev))
#endif
#ifdef OMP
            if (Fopt.eq.'omp') then
               ctmp=0.d0
!$OMP PARALLEL REDUCTION(+:ctmp) 
!$OMP DO
               do k=1,nci 
                  do j=1,nci 
                     ctmp(k)=ctmp(k)+ h_int(k,j)*c_prev(j)
                  enddo
               enddo
!$OMP END PARALLEL
               c=ccexp*(ccexp*c_prev2-2.d0*ui*dt*ctmp)  
            else
               c=ccexp*(ccexp*c_prev2-2.d0*ui*dt*matmul(h_int,c_prev))
            endif
#endif
            if (Fdis.eq."ernd") then
               do j=1,nstates
                  c(j) = c(j) - 2.d0*ccexp(j)*ui*dt*krnd*random_normal()*c_prev(j)
               enddo
            endif
            c=c/sqrt(dot_product(c,c))
            c_prev2=c_prev
            c_prev=c
            f_prev=f(:,i)
            h_int=zero
            if (Fmdm.ne."vac".and.this_Finit_int.ne."qmt") call prop_medium(i,c_prev,mu_prev,f_prev,h_int)
            call add_int_vac(f_prev,h_int)
! SC field
            if (Frad.eq."arl".and.i.gt.5) call add_int_rad(mu_prev,mu_prev2,mu_prev3, &
                                               mu_prev4,mu_prev5,h_int)

            call do_mu(c,mu_prev,mu_prev2,mu_prev3,mu_prev4,mu_prev5)
            if (mod(i,n_out).eq.0) call output(i,c,f_prev,h_int)
            ! Restart
            if (mod(i,n_restart).eq.0) then
               t=(i-1)*dt
               call wrt_restart(i,t,c,c_prev,c_prev2,nstates,iseed,mu_prev,mu_prev2,mu_prev3,mu_prev4,mu_prev5,iend) 
            endif
          enddo
       endif 

       return

      end subroutine exp_euler_prop

!------------------------------------------------------------------------
! @brief Energy and interaction terms are propagated
! via second-order Euler 
! 
! @date Created   : E. Coccia 15 Nov 2017
! Modified  :
!------------------------------------------------------------------------      
      subroutine full_euler_prop(nci)

        implicit none

        integer(i4b), intent(in)  :: nci

        integer(i4b)              :: i,j,istart,iend,k
        real(dbl)                 :: t
        complex(cmp)              :: dis(nci),ctmp(nci)

!Initialization only without restart
       if (Fres.eq.'Nonr') then
! INITIAL STEP: dpsi/dt=(psi(2)-psi(1))/dt
          c=c_prev-ui*dt*(energies*c_prev+matmul(h_int,c_prev))
          if (Fdis.eq."ernd") then
             do j=1,nstates
                c(j) = c(j) - ui*dt*krnd*random_normal()*c_prev(j)
             enddo
          endif
          if (Fdis(1:3).eq."mar".or.Fdis(1:3).eq."nma") then
             dis=disp(h_dis,c_prev,nci)
             c=c-dt*dis
             if (Fdis(5:9).eq."EuMar") then
          ! Euler-Maruyama
                c=c-ui*sqrt(dt)*matmul(h_rnd,c_prev)-dt*matmul(h_rnd2,c_prev)               
             elseif (Fdis(5:9).eq."LeiMa") then
          ! Leimkuhler-Matthews
                c=c-ui*0.5d0*sqrt(dt)*matmul(h_rnd,c_prev)-dt*matmul(h_rnd2,c_prev)
             endif
          endif
          c=c/sqrt(dot_product(c,c))
          c_prev=c

! SP 16/07/17: added call to medium propagation at step 2 to have full
! output
          f_prev=f(:,2)
          h_int=zero
          if (Fmdm.ne."vac".and.this_Finit_int.ne."qmt") then
             i=2
             call prop_medium(i,c_prev,mu_prev,f_prev,h_int)
          endif
          call add_int_vac(f_prev,h_int)
          call do_mu(c,mu_prev,mu_prev2,mu_prev3,mu_prev4,mu_prev5)
          if (mod(2,n_out).eq.0) call output(2,c,f_prev,h_int)
       endif

       if (Fres.eq.'Nonr') then
          istart=3
          iend=n_step
       elseif (Fres.eq.'Yesr') then
          istart=restart_i+1
          call add_int_vac(f_prev,h_int)
          if (Fsim.eq.'y') then 
             iend=diff_step+restart_i
          elseif (Fsim.eq.'n') then
             iend=n_step+istart-1
          endif 
       endif 


! PROPAGATION CYCLE: starts the propagation at timestep 3
! Markovian dissipation (quantum jump) -> qjump
       if (Fdis(5:9).eq."qjump") then
          !do i=3,n_step
          do i=istart,iend
! Quantum jump (spontaneous or nonradiative relaxation, pure dephasing)
! Algorithm from J. Opt. Soc. Am. B. vol. 10 (1993) 524
            dis=disp(h_dis,c_prev,nci)
#ifndef OMP
            if (i.eq.ijump+1) then
               c=c_prev-ui*dt*(energies*c_prev+matmul(h_int,c_prev))-dt*dis
            else
               c=c_prev2-2.d0*ui*dt*(energies*c_prev+matmul(h_int,c_prev))-2.d0*dt*dis
            endif
#endif
#ifdef OMP
            if (Fopt.eq.'omp') then
               ctmp=0.d0
!$OMP PARALLEL REDUCTION(+:ctmp) 
!$OMP DO
               do k=1,nci
                  do j=1,nci
                     ctmp(k)=ctmp(k)+ h_int(k,j)*c_prev(j)
                  enddo
               enddo
!$OMP END PARALLEL
               if (i.eq.ijump+1) then
                   c=c_prev-ui*dt*(energies*c_prev+ctmp)-dt*dis
               else
                   c=c_prev2-2.d0*ui*dt*(energies*c_prev+ctmp)-2.d0*dt*dis
               endif
            else
               if (i.eq.ijump+1) then
                   c=c_prev-ui*dt*(energies*c_prev+matmul(h_int,c_prev))-dt*dis
               else
                   c=c_prev2-2.d0*ui*dt*(energies*c_prev+matmul(h_int,c_prev))-2.d0*dt*dis
               endif
            endif 
#endif


! loss_norm computes: 
! norm = 1 - dtot
! dtot = dsp + dnr + dde
! Loss of the norm, dissipative events simulated
! eps -> uniform random number in [0,1]
            call loss_norm(c_prev,nstates,pjump)
            call random_number(eps)
            if (dtot.gt.eps)  then
               call quan_jump(c,c_prev,nstates,pjump)
               ijump=i
               n_jump=n_jump+1
#ifndef MPI
              if (Fwrt.eq.'yes') write(*,*) 'Quantum jump at step:', i, (i-1)*dt
#endif
               c_prev=c
            else
                c=c/sqrt(dot_product(c,c))
                c_prev2=c_prev
                c_prev=c
            endif
            f_prev=f(:,i)
            h_int=zero
            if (Fmdm.ne."vac".and.this_Finit_int.ne."qmt") call prop_medium(i,c_prev,mu_prev,f_prev,h_int)
            call add_int_vac(f_prev,h_int)
! SC field
            if (Frad.eq."arl".and.i.gt.5) call add_int_rad(mu_prev,mu_prev2,mu_prev3, &
                                                mu_prev4,mu_prev5,h_int)

            call do_mu(c,mu_prev,mu_prev2,mu_prev3,mu_prev4,mu_prev5)
            if (mod(i,n_out).eq.0) call output(i,c,f_prev,h_int)
            ! Restart
            if (mod(i,n_restart).eq.0) then
               t=(i-1)*dt
               call wrt_restart(i,t,c,c_prev,c_prev2,nstates,iseed,mu_prev,mu_prev2,mu_prev3,mu_prev4,mu_prev5,iend) 
            endif
          enddo
! Markovian dissipation (Euler-Maruyama) 
       elseif (Fdis(1:3).eq."mar") then
          !do i=3,n_step
          do i=istart,iend
! Dissipation by a continuous stochastic propagation
            call rnd_noise(w,w_prev,nstates,first)
            call add_h_rnd(h_rnd,nstates,w,w_prev)
            dis=disp(h_dis,c_prev,nci)
            if (Fdis(5:9).eq."EuMar") then
            ! Euler-Maruyama 
              c=c_prev-ui*dt*(energies*c_prev+matmul(h_int,c_prev))-dt* &
                dis-ui*sqrt(dt)*matmul(h_rnd,c_prev)- &
                dt*matmul(h_rnd2,c_prev)
            elseif (Fdis(5:9).eq."LeiMa") then
              c=c_prev-ui*dt*(energies*c_prev+matmul(h_int,c_prev))-dt* &
                dis-ui*0.5d0*sqrt(dt)* & 
                matmul(h_rnd,c_prev)-dt*matmul(h_rnd2,c_prev)
            endif
            !c=c/sqrt(dot_product(c,c))
            c_prev=c

            f_prev=f(:,i)
            h_int=zero
            if (Fmdm.ne."vac".and.this_Finit_int.ne."qmt") call prop_medium(i,c_prev,mu_prev,f_prev,h_int)
            call add_int_vac(f_prev,h_int)
! SC field
            if (Frad.eq."arl".and.i.gt.5) call add_int_rad(mu_prev,mu_prev2,mu_prev3, &
                                                mu_prev4,mu_prev5,h_int)

            call do_mu(c,mu_prev,mu_prev2,mu_prev3,mu_prev4,mu_prev5)
            if (mod(i,n_out).eq.0) call output(i,c,f_prev,h_int)
            ! Restart
            if (mod(i,n_restart).eq.0) then
               t=(i-1)*dt
               call wrt_restart(i,t,c,c_prev,c_prev2,nstates,iseed,mu_prev,mu_prev2,mu_prev3,mu_prev4,mu_prev5,iend) 
            endif
          enddo
       elseif (Fdis.eq."nodis".or.Fdis.eq."ernd") then
! No dissipation in the propagation 
          !do i=3,n_step
          do i=istart,iend
#ifndef OMP
            c=c_prev2-2.d0*ui*dt*(energies*c_prev+matmul(h_int,c_prev))
#endif
#ifdef OMP
            if (Fopt.eq.'omp') then
               ctmp=0.d0
!$OMP PARALLEL REDUCTION(+:ctmp) 
!$OMP DO
               do k=1,nci
                  do j=1,nci
                     ctmp(k)=ctmp(k)+ h_int(k,j)*c_prev(j)
                  enddo
               enddo
!$OMP END PARALLEL
               c=c_prev2-2.d0*ui*dt*(energies*c_prev+ctmp)
            else
               c=c_prev2-2.d0*ui*dt*(energies*c_prev+matmul(h_int,c_prev))
            endif
#endif

            if (Fdis.eq."ernd") then
               do j=1,nstates
                  c(j) = c(j) - 2.d0*ui*dt*krnd*random_normal()*c_prev(j)
               enddo
            endif
            c=c/sqrt(dot_product(c,c))
            c_prev2=c_prev
            c_prev=c
            f_prev=f(:,i)
            h_int=zero
            if (Fmdm.ne."vac".and.this_Finit_int.ne."qmt") call prop_medium(i,c_prev,mu_prev,f_prev,h_int)
            call add_int_vac(f_prev,h_int)
! SC field
            if (Frad.eq."arl".and.i.gt.5) call add_int_rad(mu_prev,mu_prev2,mu_prev3, &
                                                mu_prev4,mu_prev5,h_int)

            call do_mu(c,mu_prev,mu_prev2,mu_prev3,mu_prev4,mu_prev5)
            if (mod(i,n_out).eq.0) call output(i,c,f_prev,h_int)
            ! Restart
            if (mod(i,n_restart).eq.0) then
               t=(i-1)*dt
               call wrt_restart(i,t,c,c_prev,c_prev2,nstates,iseed,mu_prev,mu_prev2,mu_prev3,mu_prev4,mu_prev5,iend) 
            endif 
          enddo
       endif

       return
      
      end subroutine full_euler_prop

!------------------------------------------------------------------------
! @brief Write restart file 
! 
! @date Created   : E. Coccia 21 Nov 2017
! Modified  :
!------------------------------------------------------------------------      
      subroutine wrt_restart(i,t,c,c_prev,c_prev2,nci,iseed,mu_prev,mu_prev2,mu_prev3,mu_prev4,mu_prev5,iend)
  
       implicit none

       integer(i4b),  intent(in)  :: i,nci,iseed,iend
       real(dbl),     intent(in)  :: t
       real(dbl),     intent(in)  :: mu_prev(3),mu_prev2(3),mu_prev3(3)
       real(dbl),     intent(in)  :: mu_prev4(3),mu_prev5(3)
       complex(cmp),  intent(in)  :: c(nci), c_prev(nci), c_prev2(nci)
     
       integer(i4b)               :: j,ii
       character(20)              :: filename

#ifndef MPI
       myrank=0
#endif

       ii=777+myrank
       if (myrank+1.lt.10) then 
          write(filename,'("restart",I1)') myrank+1
       elseif (myrank+1.lt.100) then
          write(filename,'("restart",I2)') myrank+1
       elseif (myrank+1.lt.1000) then
          write(filename,'("restart",I3)') myrank+1
       elseif (myrank+1.lt.10000) then
          write(filename,'("restart",I4)') myrank+1
       elseif (myrank+1.lt.100000) then
          write(filename,'("restart",I5)') myrank+1
       endif

       !open(ii,file='restart')
       open(ii,file=filename)
       rewind(ii)
 
       write(ii,*) 'Restart time in au, Restart step'
       write(ii,*) t,i,iend-i,size(c)
       write(ii,*) 'Coefficients'
       do j=1,nci
          write(ii,*) c(j)
       enddo
       write(ii,*) 'Coefficients -1'
       do j=1,nci
          write(ii,*) c_prev(j)
       enddo
       write(ii,*) 'Coefficients -2'
       do j=1,nci
          write(ii,*) c_prev2(j)
       enddo
       if (Fdis.ne.'nodis') then
          write(ii,*) 'Seed'
          write(ii,*) iseed
          write(ii,*) 'Number of quantum jumps'
          write(ii,*) n_jump
       endif
       write(ii,*) 'Dipoles'
       write(ii,*) mu_prev(1), mu_prev(2), mu_prev(3)
       write(ii,*) mu_prev2(1), mu_prev2(2), mu_prev2(3)
       write(ii,*) mu_prev3(1), mu_prev3(2), mu_prev3(3)
       write(ii,*) mu_prev4(1), mu_prev4(2), mu_prev4(3)
       write(ii,*) mu_prev5(1), mu_prev5(2), mu_prev5(3)


       close(ii)
 
       !flush(6)
      
       return

      end subroutine wrt_restart 

      end module



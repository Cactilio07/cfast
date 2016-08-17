module conduction_routines

    use precision_parameters

    use convection_routines, only: convective_flux

    use wallptrs
    use cenviro
    use solver_data, only: nofwt, i_wallmap
    use room_data
    use cparams

    implicit none

    private

    public conduction, conductive_flux

    contains

! --------------------------- conduction -------------------------------------------

    subroutine conduction(update,dt,fluxes_total,delta)

    !     routine: conduction (main conduction routine)
    !     purpose: interface between calculate_residuals and the conduction calculation.
    !              for each active wall surface in each routine this
    !              routine calculates the residual function
    !               q'' + k dt/dx, which when zero is simply fourier's
    !              law of heat conduction.
    !     arguments: update  we don't keep solution unless update is 1 or 2. if update is 2 then
    !                        we don't calculate delta or use fluxes_total
    !                dt time step interval from last valid solution point
    !                fluxes_total  total flux striking walls
    !                delta   the residual of q'' + k dt/dx

    integer, intent(in) :: update
    real(eb), intent(in) :: dt, fluxes_total(mxrooms,nwal)
    real(eb), intent(out) :: delta(*)

    real(eb) :: tgrad(2), vtgrad(4*mxrooms), wtemps(nnodes), walldx(nnodes)

    real(eb) :: twint, twext, tgas, wfluxin, wfluxout, wfluxsave, frac, yb, yt, dflor, yy, fu, fluxu, fluxl, tderv
    real(eb) :: k_w(mxslb), c_w(mxslb), rho_w(mxslb)
    integer :: nslab_w, numnode(mxslb+1)
    integer :: ibeg, iend, iw, iroom, iwall, icond, iweq, iwb, jj, j

    type(room_type), pointer :: roomptr

    integer, dimension(nwal) :: irevwc = (/2,1,3,4/)

    ! solve conduction problem for all walls

    ibeg = 1
    iend = nhcons
    wfluxin = 0.0_eb
    wfluxout = 0.0_eb

    do iw = ibeg, iend
        iroom = i_hconnections(iw,w_from_room)
        iwall = i_hconnections(iw,w_from_wall)
        icond = nofwt + iw

        roomptr => roominfo(iroom)
        if (adiabatic_walls.or..not.roomptr%surface_on(iwall)) then
            vtgrad(iw) = 0.0_eb
        else

            ! use exterior wall temperature from last time step to ...
            twint = roomptr%t_surfaces(1,iwall)
            twext = roomptr%t_surfaces(2,iwall)
            tgas = exterior_temperature
            iweq = i_wallmap(iroom,iwall) - nofwt
            iwb = i_hconnections(iweq,w_boundary_condition)

            ! compute flux seen by exterior of wall
            if (iwb==3) then

                ! back wall is connected to the outside
                call convective_flux (irevwc(iwall),tgas,twext,wfluxout)
                wfluxout = wfluxout + sigma*(tgas**4-twext**4)
                wfluxsave = wfluxout

                ! back wall is connected to rooms defined by hheat_connections with fractions defined by heat_frac.
                if (roomptr%iheat/=0.and.iwall/=1.and.iwall/=2) then
                    wfluxout = 0.0_eb
                    do jj = 1, roomptr%nheats
                        j = roomptr%hheat_connections(jj)
                        frac = roomptr%heat_frac(j)
                        if (iwall==3) then
                            yb = roomptr%depth(l)
                            yt = roomptr%z1
                        else if (iwall==4) then
                            yb = 0.0_eb
                            yt = roomptr%depth(l)
                        end if
                        dflor = roominfo(j)%z0 - roomptr%z0
                        yy = roominfo(j)%depth(l) + dflor
                        if (j/=nrm1+1) then
                            if (yy>yt) then
                                fu = 0.0_eb
                            else if (yy<yb) then
                                fu = 1.0_eb
                            else
                                if (yb/=yt) then
                                    fu = (yt-yy)/(yt-yb)
                                else
                                    fu = 0.0_eb
                                end if
                            end if
                            fluxu = fu*fluxes_total(j,3)
                            fluxl = (1.0_eb-fu)*fluxes_total(j,4)
                        else
                            fluxu = wfluxsave
                            fluxl = 0.0_eb
                        end if
                        wfluxout = wfluxout + frac*(fluxu + fluxl)
                    end do
                end if
            end if
            k_w(1:mxslb) = roomptr%k_w(1:mxslb,iwall)
            c_w(1:mxslb) = roomptr%c_w(1:mxslb,iwall)
            rho_w(1:mxslb) = roomptr%rho_w(1:mxslb,iwall)
            nslab_w = roomptr%nslab_w(iwall)
            numnode = roomptr%nodes_w(1:mxslb+1,iwall)
            wtemps = roomptr%t_profile(1:nnodes,iwall)
            walldx = roomptr%walldx(1:nnodes,iwall)
            call conductive_flux (update,twint,twext,dt,k_w,c_w,rho_w, &
                wtemps,walldx,numnode,nslab_w,wfluxin,wfluxout,iwb,tgrad,tderv)
            roomptr%t_profile(1:nnodes,iwall) = wtemps
            ! store wall gradient
            vtgrad(iw) = tgrad(2)

            ! compute partial of wall temperature equation with respect to the wall temperature.  we assume that the
            ! partials of convective heat flux and radiative heat flux with respect to wall temperature have already
            ! been computed.  (if they were not then we wouldn't know heat flux striking the wall!
        end if
    end do

    ! dassl will try to force delta to be zero, so that fourier's law, q = -k dt/dx, is satisfied at the wall surface
    if (update/=2) then
        do iw = 1, nhcons
            icond = nofwt + iw
            iroom = i_hconnections(iw,w_from_room)
            roomptr => roominfo(iroom)
            iwall = i_hconnections(iw,w_from_wall)
            delta(icond) = fluxes_total(iroom,iwall) + vtgrad(iw)*roomptr%k_w(1,iwall)
        end do
    end if

    return
    end subroutine conduction

! --------------------------- conductive_flux -------------------------------------------

    subroutine conductive_flux (update,tempin,tempout,dt,wk,wspec,wrho,wtemp,walldx,numnode,nslab,wfluxin,wfluxout,iwbound,&
       tgrad,tderv)


    ! routine:  conductive_flux
    ! purpose: handles cfast conduction
    ! arguments: update   we don't keep solution unless update is 1 or 2
    !            tempin   temperature at interior wall
    !            tempout  temperature at exterior wall, not used now
    !            dt       time step interval from last valid solution point
    !            wk       wall thermal conductivity
    !            wspec    wall specific heat
    !            wrho     wall density
    !            wtemp    wall temperature profile
    !            walldx   wall position points
    !            numnode  number of nodes in each slab
    !            nslab    number of slabs
    !            wfluxin  flux striking interior wall
    !            wfluxout flux striking exterior wall
    !            iwbound  type of boundary condition for exterior wall (1=constant temperature, 2=insulated, 3=flux based
    !                     on ambient temperature on outside wall, 4=flux on both interior and exterior walls)
    !            tgrad    temperature gradient
    !            tderv    partial of temperature gradient with respect to wall surface temperature.
    !                     this number is used to calculate wall jacobian elements.

    real(eb), intent(in) :: wk(*), wspec(*), wrho(*), walldx(*)
    real(eb), intent(out) :: wtemp(*), tgrad(2)
    integer, intent(in) :: update, nslab, iwbound, numnode(*)


    integer :: nx, i, ibeg, iend, islab, nintx, ibreak
    real(eb) :: a(nnodes), b(nnodes), c(nnodes), tnew(nnodes), tderiv(nnodes), ddif(3)
    real(eb) :: tempin, tempout, wfluxin, wfluxout, xkrhoc, s, dt, hi, him1, tderv

    nx = numnode(1)

    ! construct right hand side (rhs) of tri-diagonal system for interior nodes.  rhs at boundary and slab break
    ! points are defined farther down.
    tnew(2:nx-1) = wtemp(2:nx-1)

    ! set up tri-diagonal coefficient matrix

    ! setup first row
    if (iwbound/=4) then
        a(1) = 1.0_eb
        b(1) = 0.0_eb
        c(1) = 0.0_eb
        tnew(1) = tempin
    else
        a(1) = 1.0_eb
        b(1) = 0.0_eb
        c(1) = -1.0_eb
        tnew(1) = walldx(1)*wfluxin/wk(1)
    end if

    ! do interior points for each slab
    iend = 0
    do islab = 1, nslab
        nintx = numnode(1+islab)
        xkrhoc = wk(islab)/(wspec(islab)*wrho(islab))
        s = 2.0_eb*dt*xkrhoc
        ibeg = iend + 2
        iend = ibeg + nintx - 1
        do i = ibeg, iend
            hi = walldx(i)
            him1 = walldx(i-1)
            a(i) = 1.0_eb + s/(hi*him1)
            b(i) = -s/(him1*(hi+him1))
            c(i) = -s/(hi*(hi+him1))
        end do
    end do

    ! do break points between each slab
    ibreak = 1
    do islab = 2, nslab
        nintx = numnode(islab)
        ibreak = ibreak + nintx + 1
        b(ibreak) = wk(islab-1)/walldx(ibreak-1)
        c(ibreak) = wk(islab)/walldx(ibreak)
        a(ibreak) = -(b(ibreak)+c(ibreak))
        tnew(ibreak) = 0.0_eb
    end do

    ! setup last row, note: last row depends on form of boundary condition
    if (iwbound==1) then

        ! constant temperature boundary condition (if we ever solve for both interior and exterior wall temperatures
        ! then use change tnew(nx) = tamb to tnew(nx) = tempout)
        a(nx) = 1.0_eb
        b(nx) = 0.0_eb
        c(nx) = 0.0_eb
        tnew(nx) = tempout
    else if (iwbound==2) then

        ! insulated boundary condition
        a(nx) = 1.0_eb
        b(nx) = -1.0_eb
        c(nx) = 0.0_eb
        tnew(nx) = 0.0_eb
    else if (iwbound==3.or.iwbound==4) then

        ! flux boundary condition (using lagged temperatures
        a(nx) = 1.0_eb
        b(nx) = -1.0_eb
        c(nx) = 0.0_eb
        tnew(nx) = walldx(nx-1)*wfluxout/wk(nslab)
    end if

    ! now perform an l-u factorization of this matrix (see atkinson p.455) note: matrix is
    ! diagonally dominant so we don't have to pivot

    ! note we do the following in case a(1) is not 1
    c(1) = c(1)/a(1)
    do i = 2, nx - 1
        a(i) = a(i) - b(i)*c(i-1)
        c(i) = c(i)/a(i)
    end do
    a(nx) = a(nx) - b(nx)*c(nx-1)
    tderiv(1:nx) = 0.0_eb
    tderiv(1) = 1.0_eb

    ! now construct guess at new temperature profile

    ! forward substition
    tnew(1) = tnew(1)/a(1)
    tderiv(1) = tderiv(1)/a(1)
    do i = 2, nx
        tnew(i) = (tnew(i)-b(i)*tnew(i-1))/a(i)
        tderiv(i) = (tderiv(i)-b(i)*tderiv(i-1))/a(i)
    end do

    ! backward substition
    do i = nx - 1, 1, -1
        tnew(i) = tnew(i) - c(i)*tnew(i+1)
        tderiv(i) = tderiv(i) - c(i)*tderiv(i+1)
    end do

    ! we don't keep solution unless update is 1 or 2
    if (update/=0) then
        wtemp(1:nx) = tnew(1:nx)
    end if

    ! estimate temperature gradient at wall surface by constructing a quadratic polynomial that
    ! interpolates first three data points in the temperature profile.  we will use divided differences.

    ! first divided difference
    ddif(1) = (tnew(2)-tnew(1))/walldx(1)
    ddif(2) = (tnew(3)-tnew(2))/walldx(2)

    ! second divided difference
    ddif(2) = (ddif(2)-ddif(1))/(walldx(1)+walldx(2))

    tgrad(1) = (ddif(1)-ddif(2)*walldx(1))
    tgrad(2) = (tnew(2)-tnew(1))/walldx(1)
    tderv = tderiv(2)
    return

    end subroutine conductive_flux

end module conduction_routines

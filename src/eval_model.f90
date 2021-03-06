module eval_model 

  use public_var
  use data_type 
  use var_lookup

  implicit none

  private

  public :: objfn 
  public :: out_opt_sim

contains

!************************************
! perform model evaluation 
!************************************
function objfn( calParam )
  use mpr_routine,   only: mpr
  use globalData,    only: betaCalScale, betaMaster, parSubset, gammaSubset, nBetaGammaCal, nSoilParModel, nVegParModel
  use model_wrapper, only: read_hru_id, read_soil_param, adjust_param, replace_param, write_soil_param, read_sim
  implicit none
  !input variables
  real(dp),             intent(in)  :: calParam(:)                   ! parameter in namelist, not necessarily all parameters are calibrated
  !local variables
  type(var_d)                       :: calParStr(nBetaGammaCal)      ! parameter storage converted from parameter array 
  type(var_d)                       :: pnormCoef(size(betaCalScale)) ! parameter storage converted from parameter array 
  real(dp)                          :: objfn                         ! object function value 
  integer(i4b)                      :: iPar                          ! loop index for parameter 
  integer(i4b)                      :: idx                           ! 
  logical(lgc),         allocatable :: mask(:)                       ! 1D mask
  integer(i4b)                      :: hruID(nHru)                   ! Hru ID
  real(dp)                          :: param(nHru,TotNPar)           ! original soil parameter (model hru x parameter)
  real(dp)                          :: adjParam(nHru,TotNPar)        ! adjustet soil parameter (model hru x parameter) 
  type(var_d),          allocatable :: paramGammaStr(:)              ! calibratin gamma parameter
  real(dp),             allocatable :: obs(:)                        ! observation (number of basin*number of time step)
  real(dp),             allocatable :: sim(:,:)                      ! instantaneous sim value (hru x number of time step)
  real(dp),             allocatable :: simBasin(:,:)                 ! instantaneous basin aggregated sim value (basin x number of time step)
  real(dp),             allocatable :: simBasinRouted(:,:)           ! routed sim value (basin x number of time step)
  real(dp),             allocatable :: hModel(:,:)                   ! storage of model layer thickness at model layer x model hru 
  type(namedvar2),      allocatable :: parMxyMz(:)                   ! storage of model soil parameter at model layer x model hru 
  type(namedvar2),      allocatable :: vegParMxy(:)                  ! storage of model vege parameter at month (or annual) x model hru
  real(dp)                          :: ushape,uscale                 ! two routing parameter
  integer(i4b)                      :: err                           ! error id 
  character(len=strLen)             :: message                       ! error message
  character(len=strLen)             :: cmessage                      ! error message from subroutine

  err=0; message='eval_objfn/' ! to initialize error control
  allocate(obs(nbasin*sim_len))
  allocate(sim(nHru,sim_len))
  allocate(simBasin(nbasin,sim_len))
  allocate(simBasinRouted(nbasin,sim_len))
  idx=1
  do iPar=1,nBetaGammaCal ! put calpar vector from optimization routine output parameter data strucure 
    if (parSubset(iPar)%perLyr)then
      allocate(calParStr(iPar)%var(nLyr))
      calParStr(iPar)%var=calParam(idx:idx+nLyr-1)
      idx=idx+nLyr
    else
      allocate(calParStr(iPar)%var(1))
      calParStr(iPar)%var=calParam(idx)
      idx=idx+1
    endif
  end do
  do iPar=1,size(betaCalScale) ! put calpar vector from optimization routine output pnorm coef. data strucure
    allocate(pnormCoef(iPar)%var(2))
    pnormCoef(iPar)%var=calParam(idx:idx+1)
    idx=idx+2
  end do
  call read_hru_id(idModel, hruID, err, cmessage)    ! to get hruID
  if (err/=0)then; print*,trim(message)//trim(cmessage);stop;endif
  call read_soil_param(idModel, param, err, cmessage)! to read soil param template (=param) 
  if (err/=0)then; print*,trim(message)//trim(cmessage);stop;endif
  adjParam=param
  if ( any(parSubset(:)%beta == "beta") )then ! calpar include multipliers for original model parameter 
    call adjust_param(idModel, param, calParStr, adjParam, err, cmessage) ! to adjust "param" with multiplier method and output in adjParam 
    if (err/=0)then; print*,trim(message)//trim(cmessage);stop;endif
  endif
  if ( any(parSubset(:)%beta /= "beta") )then ! calPar includes gamma parameters to be used for MPR 
    allocate(hModel(nLyr,nHru),stat=err);      if(err/=0)then;print*,trim(message)//'error allocating hModel';stop;endif
    allocate(parMxyMz(nSoilParModel),stat=err);if(err/=0)then;print*,trim(message)//'error allocating parMxyMz';stop;endif
    allocate(vegParMxy(nVegParModel),stat=err);if(err/=0)then;print*,trim(message)//'error allocating vegParMxy';stop;endif
    do iPar=1,nSoilParModel
      allocate(parMxyMz(iPar)%varData(nLyr,nHru),stat=err)
    enddo
    do iPar=1,nVegParModel
      allocate(vegParMxy(iPar)%varData(nMonth,nHru),stat=err)
    enddo
    allocate(mask(nBetaGammaCal))
    mask=parSubset(:)%beta/="beta"
    allocate(paramGammaStr(count(mask)))
    paramGammaStr=pack(calParStr,mask)
    do iPar=1,size(paramGammaStr)
      if (size(paramGammaStr(iPar)%var)>1)then;print*,trim(message)//'gammaParameter should not have perLayer value';stop;endif
    enddo
    call mpr(hruID, pnormCoef, paramGammaStr, gammaSubset, hModel, parMxyMz, vegParMxy, err, cmessage) ! to output model layer thickness and model parameter via MPR
    if(err/=0)then;print*,trim(message)//trim(cmessage);stop;endif
    call replace_param(idModel, adjParam, hModel, parMxyMz, adjParam, err, cmessage)
    if(err/=0)then;print*,trim(message)//trim(cmessage);stop;endif
  endif
  call write_soil_param(idModel, hruID, adjParam, err, cmessage)
  if(err/=0)then;print*,trim(message)//trim(cmessage);stop;endif
  call system(executable) ! to run hydrologic model   
  call read_obs(obs, err, cmessage)
  if(err/=0)then;print*,trim(message)//trim(cmessage);stop;endif
  call read_sim(idModel, sim, err, cmessage)
  if(err/=0)then;print*,trim(message)//trim(cmessage);stop;endif
  call agg_hru_to_basin(sim, simBasin, err, cmessage) ! aggregate hru sim to basin total sim 
  if(err/=0)then;print*,trim(message)//trim(cmessage);stop;endif
  ! route sim for each basin
  ushape=betaMaster(ixBeta%uhshape)%val
  uscale=betaMaster(ixBeta%uhscale)%val
  do iPar=1,nBetaGammaCal
    select case( parSubset(iPar)%pname )
      case('uhshape');  ushape = calParStr( iPar )%var(1)
      case('uhscale');  uscale = calParStr( iPar )%var(1)
     end select
  end do
  call route_q(simBasin, simBasinRouted, ushape, uscale, err, cmessage)
  if (err/=0)then; print*,trim(message)//trim(cmessage);stop;endif
  if (opt == 2) then
    call out_opt_sim(simBasinRouted, obs) ! to just output optimal run
  else
    select case( trim(objfntype) )
    case('rmse');         call calc_rmse_region      (simBasinRouted, obs, agg, objfn) 
    case('log-rmse+rmse');call calc_log_rmse_region  (simBasinRouted, obs, agg, objfn) 
    case('month-rmse');   call calc_month_rmse_region(simBasinRouted, obs, agg, objfn) 
    case('nse');          call calc_nse_region       (simBasinRouted, obs, agg, objfn) 
    case('log-nse+nse');  call calc_log_nse_region   (simBasinRouted, obs, agg, objfn) 
    case('month-nse');    call calc_month_nse_region (simBasinRouted, obs, agg, objfn) 
    case('kge');          call calc_kge_region       (simBasinRouted, obs, agg, objfn) 
    case('log-kge+kge');  call calc_log_kge_region   (simBasinRouted, obs, agg, objfn) 
    case('sigBias');      call calc_sigBias_region   (simBasinRouted, obs, agg, objfn) 
    case default; print*,trim(message)//'objective function not recognized';stop
    end select
  endif
  return
end function

!************************************
! compute daily RMSE 
!************************************
subroutine calc_rmse_region(sim, obs, agg, objfn)
  implicit none
  !input variables 
  real(dp), dimension(:,:), intent(in)    :: sim 
  real(dp), dimension(:),   intent(in)    :: obs 
  integer(i4b),             intent(in)    :: agg          ! basin aggregation method
  !output variables
  real(dp),                 intent(out)   :: objfn
  !local variables
  integer(i4b)                            :: err          ! error code
  character(len=strLen)                   :: message      ! error message
  integer(i4b)                            :: ibasin,offset
  real(dp),    allocatable,dimension(:,:) :: simIn
  real(dp),    allocatable,dimension(:)   :: obsIn
  integer(i4b),allocatable,dimension(:)   :: basin_id
  real(dp),    allocatable,dimension(:)   :: obj_fun_weight
  real(dp),    allocatable,dimension(:)   :: basin_rmse
  integer(i4b)                            :: nTime        !number of time step 

  ! initialize error control
  err=0; message=trim(message)//'calc_rmse_region/'
  allocate(simIn(nbasin,sim_len))
  allocate(obsIn(nbasin*sim_len))
  allocate(obj_fun_weight(nbasin))
  allocate(basin_rmse(nbasin))
  allocate(basin_id(nbasin))
  !read in basin weight file
  !this file determines how much each basin contributes to the total rmse
  !weights need to sum to 1 in the file
  open (UNIT=58,file=trim(basin_objfun_weight_file),form='formatted',status='old')
  read (UNIT=58,fmt=*) ( basin_id(ibasin),obj_fun_weight(ibasin), ibasin=1,nbasin)
  close(UNIT=58)
  obsIn = obs 
  simIn = sim
  !need to make sure i'm using the appropriate parts of the catenated region observed streamflow timeseries
  do ibasin = 0,nbasin-1
    !offset places me at the start of each basin
    offset = ibasin*sim_len
    !then run from the starting calibration point to the ending calibration point
    nTime=end_cal-start_cal+1
    basin_rmse(ibasin+1) = sqrt( sum((simIn(ibasin+1,start_cal:end_cal)-obsIn(offset+start_cal:offset+end_cal))**2)/real(nTime) )
  enddo
  select case( agg )
    case(1); objfn = sum(basin_rmse*obj_fun_weight)
    case(2); objfn = (sum((basin_rmse*obj_fun_weight)**6.0_dp))**(1.0_dp/6.0_dp)
    case default; print*,'basin aggregation method not recognized';stop
  end select
  return
end subroutine

!************************************
! compute daily log(RMSE)+RMSE 
!************************************
subroutine calc_log_rmse_region(sim, obs, agg, objfn)
  implicit none
  !input variables 
  real(dp), dimension(:,:), intent(in)    :: sim 
  real(dp), dimension(:),   intent(in)    :: obs 
  integer(i4b),             intent(in)    :: agg          ! basin aggregation method
  !output variables
  real(dp),                 intent(out)   :: objfn        ! final objective function value
  !local variables
  integer(i4b)                            :: err          ! error code
  character(len=strLen)                   :: message      ! error message
  integer(i4b)                            :: ibasin,offset
  real(dp),    allocatable,dimension(:,:) :: simIn,logSimIn
  real(dp),    allocatable,dimension(:)   :: obsIn,logObsIn
  integer(i4b),allocatable,dimension(:)   :: basin_id
  real(dp),    allocatable,dimension(:)   :: obj_fun_weight
  real(dp),    allocatable,dimension(:)   :: basin_objfn
  integer(i4b)                            :: nTime        !number of time step 

  ! initialize error control
  err=0; message=trim(message)//'calc_log_rmse_region/'
  allocate(simIn(nbasin,sim_len))
  allocate(obsIn(nbasin*sim_len))
  allocate(logSimIn(nbasin,sim_len))
  allocate(logObsIn(nbasin*sim_len))
  allocate(obj_fun_weight(nbasin))
  allocate(basin_objfn(nbasin))
  allocate(basin_id(nbasin))
  !read in basin weight file
  !this file determines how much each basin contributes to the total rmse
  !weights need to sum to 1 in the file
  open (UNIT=58,file=trim(basin_objfun_weight_file),form='formatted',status='old')
  read (UNIT=58,fmt=*) ( basin_id(ibasin),obj_fun_weight(ibasin), ibasin=1,nbasin)
  close(UNIT=58)
  obsIn = obs 
  simIn = sim
  logObsIn =log(obs)
  logSimIn = log(sim)
  !need to make sure i'm using the appropriate parts of the catenated region observed streamflow timeseries
  do ibasin = 0,nbasin-1
    !offset places me at the start of each basin
    offset = ibasin*sim_len
    !then run from the starting calibration point to the ending calibration point
    nTime=end_cal-start_cal+1
    basin_objfn(ibasin+1)=sqrt( sum((simIn(ibasin+1,start_cal:end_cal)-obsIn(offset+start_cal:offset+end_cal))**2)/real(nTime) )
    basin_objfn(ibasin+1)=basin_objfn(ibasin+1)+sqrt( sum((logSimIn(ibasin+1,start_cal:end_cal)-logObsIn(offset+start_cal:offset+end_cal))**2)/real(nTime) )
    basin_objfn(ibasin+1)=basin_objfn(ibasin+1)/2.0_dp
  enddo
  select case( agg )
  case(1); objfn = sum(basin_objfn*obj_fun_weight)
  case(2); objfn = (sum((basin_objfn*obj_fun_weight)**6.0_dp))**(1.0_dp/6.0_dp)
  end select
  return
end subroutine

!************************************
! compute monthly RMSE 
!************************************
subroutine calc_month_rmse_region(sim, obs, agg, objfn)
  implicit none
  !input variables 
  real(dp), dimension(:,:), intent(in)    :: sim 
  real(dp), dimension(:),   intent(in)    :: obs 
  integer(i4b),             intent(in)    :: agg          ! basin aggregation method
  !output variables
  real(dp),                 intent(out)   :: objfn        ! final objective function 
  !local variables
  integer(i4b)                            :: err          ! error code
  character(len=strLen)                   :: message      ! error message
  integer(i4b)                            :: itime,ibasin,offset
  real(dp)                                :: sum_sqr
  real(dp),    allocatable,dimension(:,:) :: simIn
  real(dp),    allocatable,dimension(:)   :: obsIn
  integer(i4b),allocatable,dimension(:)   :: basin_id
  real(dp),    allocatable,dimension(:)   :: obj_fun_weight
  real(dp),    allocatable,dimension(:)   :: basin_rmse
  integer(i4b)                            :: nTime        !number of time step 
  integer(i4b)                            :: start_ind, end_ind
  real(dp)                                :: simAgg, obsAgg

  ! initialize error control
  err=0; message=trim(message)//'calc_month_rmse_region/'
  allocate(simIn(nbasin,sim_len))
  allocate(obsIn(nbasin*sim_len))
  allocate(obj_fun_weight(nbasin))
  allocate(basin_rmse(nbasin))
  allocate(basin_id(nbasin))
  !read in basin weight file
  !this file determines how much each basin contributes to the total rmse
  !weights need to sum to 1 in the file
  open (UNIT=58,file=trim(basin_objfun_weight_file),form='formatted',status='old')
  read (UNIT=58,fmt=*) ( basin_id(ibasin),obj_fun_weight(ibasin), ibasin=1,nbasin)
  close(UNIT=58)
  obsIn = obs 
  simIn = sim
  do ibasin = 0,nbasin-1
    !offset places me at the start of each basin
    offset = ibasin*sim_len
    !then run from the starting calibration point to the ending calibration point
    sum_sqr = 0.0
    nTime = floor(((end_cal-start_cal)+1)/30.0_dp)  !use 30 day months uniformly to make it easier
    start_ind = start_cal
    end_ind   = start_cal+29
    do itime = 1,nTime
      simAgg  = sum(simIn(ibasin+1,start_ind:end_ind))/30.0_dp
      obsAgg  = sum(obsIn(offset+start_ind:offset+end_ind))/30.0_dp
      sum_sqr = sum_sqr + ((simAgg-obsAgg)**2)
      start_ind = end_ind+1
      end_ind   = end_ind+29
    enddo
    basin_rmse(ibasin+1) = sqrt(sum_sqr/real(nTime))
  enddo
  select case( agg )
  case(1); objfn = sum(basin_rmse*obj_fun_weight)
  case(2); objfn = (sum((basin_rmse*obj_fun_weight)**6.0_dp))**(1.0_dp/6.0_dp)
  end select
end subroutine

!*****************************************************
! Compute daily NSE
!*****************************************************
subroutine calc_nse_region(sim, obs, agg, objfn)
  implicit none
  !input variables
  real(dp), dimension(:,:), intent(in)  :: sim 
  real(dp), dimension(:),   intent(in)  :: obs
  integer(i4b),             intent(in)  :: agg                ! basin aggregation method
  !output variables
  real(dp),                 intent(out) :: objfn 
  !local variables
  integer(i4b)                          :: itime,ibasin,offset
  real(dp)                              :: sumSqrErr
  real(dp)                              :: sumSqrDev
  real(dp)                              :: sumQ
  real(dp)                              :: meanQ
  real(dp)                              :: Smax=0.6_dp        ! upper threshold for score function 
  real(dp)                              :: Smin=0.3_dp        ! lower threshold for score function 
  integer(i4b),dimension(nbasin)        :: basin_id
  real(dp),    dimension(nbasin)        :: obj_fun_weight
  real(dp),    dimension(nbasin)        :: basin_nse          ! nse for individual basin
  real(dp),    dimension(nbasin)        :: basin_score        ! score function  

  ! Read basin weight file
  ! this file determines how much each basin contributes to the total objective function 
  ! weights need to sum to 1 in the file
  open (UNIT=58,file=trim(basin_objfun_weight_file),form='formatted',status='old')
  read (UNIT=58,fmt=*) ( basin_id(ibasin),obj_fun_weight(ibasin), ibasin=1,nbasin )
  close(UNIT=58)
  do ibasin = 0,nbasin-1
    !offset places me at the start of each basin
    offset = ibasin*sim_len
    sumSqrDev = 0.0
    sumSqrErr = 0.0
    ! Compute Qob mean
    sumQ = sum(obs(start_cal+offset:end_cal+offset))
    meanQ = sumQ/real((end_cal-start_cal+1))
    ! Compute sum of squre of error and deviation from menan (for obs) 
    do itime = start_cal,end_cal
      sumSqrDev = sumSqrDev + (obs(itime+offset)-meanQ)**2
      sumSqrErr = sumSqrErr + (sim(ibasin+1,itime)-obs(itime+offset))**2
    enddo
    ! Compute nse for current basin 
    basin_nse(ibasin+1) = sumSqrErr/sumSqrDev
  enddo
  select case( agg )
  case(1); objfn = sum(basin_nse*obj_fun_weight)
  case(2); objfn = (sum((basin_nse*obj_fun_weight)**6.0_dp))**(1.0_dp/6.0_dp)
  case(3); 
    where(basin_nse<=Smin) basin_score=1.0_dp
    where(basin_nse>Smax)  basin_score=0.0_dp
    where(basin_nse>Smin .and. basin_nse<=Smax) basin_score=(Smax-basin_nse)/(Smax-Smin)
    objfn=sum(basin_score)
  end select
  return
end subroutine

!*****************************************************
! Compute daily log(NSE)+NSE
!*****************************************************
subroutine calc_log_nse_region(sim, obs, agg, objfn)
  implicit none
  !input variables
  real(dp), dimension(:,:), intent(in)  :: sim 
  real(dp), dimension(:),   intent(in)  :: obs
  integer(i4b),             intent(in)  :: agg          ! basin aggregation method
  !output variables
  real(dp),                 intent(out) :: objfn 
  !local variables
  integer(i4b)                              :: itime,ibasin,offset
  real(dp)                                  :: Smax=0.6_dp        ! upper threshold for score function 
  real(dp)                                  :: Smin=0.3_dp        ! lower threshold for score function 
  real(dp),   allocatable,dimension(:,:)    :: simIn,logSimIn
  real(dp),   allocatable,dimension(:)      :: obsIn,logObsIn
  real(dp)                                  :: sumSqrErr,log_sumSqrErr
  real(dp)                                  :: sumSqrDev,log_sumSqrDev
  real(dp)                                  :: meanQ,log_meanQ
  real(dp),               dimension(nbasin) :: basin_score          ! score function  
  integer(i4b),           dimension(nbasin) :: basin_id
  real(dp),               dimension(nbasin) :: obj_fun_weight
  real(dp),               dimension(nbasin) :: basin_objfn          ! nse for individual basin

  ! variable allocation
  allocate(simIn(nbasin,sim_len))
  allocate(obsIn(nbasin*sim_len))
  allocate(logSimIn(nbasin,sim_len))
  allocate(logObsIn(nbasin*sim_len))
  ! Read basin weight file
  ! this file determines how much each basin contributes to the total objective function 
  ! weights need to sum to 1 in the file
  open (UNIT=58,file=trim(basin_objfun_weight_file),form='formatted',status='old')
  read (UNIT=58,fmt=*) ( basin_id(ibasin),obj_fun_weight(ibasin), ibasin=1,nbasin )
  close(UNIT=58)
  obsIn = obs 
  simIn = sim
  where(obsIn<verySmall) obsIn=verySmall
  where(simIn<verySmall) simIn=verySmall
  logObsIn =log(obsIn)
  logSimIn =log(simIn)
  do ibasin = 0,nbasin-1
    !offset places me at the start of each basin
    offset = ibasin*sim_len
    sumSqrDev = 0.0
    sumSqrErr = 0.0
    log_sumSqrDev = 0.0
    log_sumSqrErr = 0.0
    ! Compute Qob mean
    meanQ     = sum(obsIn(start_cal+offset:end_cal+offset))/real((end_cal-start_cal+1))
    log_meanQ = sum(logObsIn(start_cal+offset:end_cal+offset))/real((end_cal-start_cal+1))
    ! Compute sum of squre of error and deviation from menan (for obs) 
    do itime = start_cal,end_cal
      sumSqrDev = sumSqrDev + (obsIn(itime+offset)-meanQ)**2
      sumSqrErr = sumSqrErr + (simIn(ibasin+1,itime)-ObsIn(itime+offset))**2
      log_sumSqrDev = log_sumSqrDev + (logObsIn(itime+offset)-log_meanQ)**2
      log_sumSqrErr = log_sumSqrErr + (logSimIn(ibasin+1,itime)-logObsIn(itime+offset))**2
    enddo
    basin_objfn(ibasin+1) = sumSqrErr/sumSqrDev
    basin_objfn(ibasin+1) = basin_objfn(ibasin+1)+log_sumSqrErr/log_sumSqrDev
    basin_objfn(ibasin+1) = basin_objfn(ibasin+1)/2.0_dp
  enddo
  select case( agg )
  case(1); objfn = sum(basin_objfn*obj_fun_weight)
  case(2); objfn = (sum((basin_objfn*obj_fun_weight)**6.0_dp))**(1.0_dp/6.0_dp)
  case(3); 
    where(basin_objfn<=Smin) basin_score=1.0_dp
    where(basin_objfn>Smax)  basin_score=0.0_dp
    where(basin_objfn>Smin .and. basin_objfn<=Smax) basin_score=(Smax-basin_objfn)/(Smax-Smin)
    objfn=sum(basin_score)
  end select
  return
end subroutine

!*****************************************************
! Compute monthly NSE
!*****************************************************
subroutine calc_month_nse_region(sim, obs, agg, objfn)
  implicit none
  !input variables
  real(dp), dimension(:,:), intent(in)  :: sim 
  real(dp), dimension(:),   intent(in)  :: obs
  integer(i4b),             intent(in)  :: agg          ! basin aggregation method
  !output variables
  real(dp),                 intent(out) :: objfn 
  !local variables
  integer(i4b)                          :: itime,ibasin,offset
  real(dp)                              :: sumSqrErr
  real(dp)                              :: sumSqrDev
  real(dp)                              :: sumQ
  real(dp)                              :: meanQ
  integer(i4b),allocatable,dimension(:) :: basin_id
  real(dp),allocatable,dimension(:)     :: obj_fun_weight
  real(dp),allocatable,dimension(:)     :: basin_nse          ! nse for individual basin
  integer(i4b)                          :: nTime            ! for monthly rmse calculation
  integer(i4b)                          :: start_ind, end_ind
  real(dp)                              :: month_sim, month_obs

  ! variable allocation
  allocate(obj_fun_weight(nbasin))
  allocate(basin_nse(nbasin))
  allocate(basin_id(nbasin))
  ! Read basin weight file
  ! this file determines how much each basin contributes to the total objective function 
  ! weights need to sum to 1 in the file
  open (UNIT=58,file=trim(basin_objfun_weight_file),form='formatted',status='old')
  read (UNIT=58,fmt=*) ( basin_id(ibasin),obj_fun_weight(ibasin), ibasin=1,nbasin )
  close(UNIT=58)
  !need to make sure i'm using the appropriate parts of the catenated region observed obs timeseries
  do ibasin = 0,nbasin-1
    !offset places me at the start of each basin
    offset = ibasin*sim_len
    sumQ = 0.0
    sumSqrDev = 0.0
    sumSqrErr = 0.0
    nTime = floor(((end_cal-start_cal)+1)/30.0)  !use 30 day months uniformly to make it easier
    ! Compute montly observed Q
    ! Indices of start and end for first month
    start_ind = start_cal
    end_ind = start_cal + 29
    do itime = 1,nTime
      month_obs = sum(obs(offset+start_ind:offset+end_ind))
      sumQ       = sumQ+month_obs
      !update starting and ending indice for next month step
      start_ind = end_ind+1
      end_ind = end_ind + 29
    enddo
    meanQ = sumQ/real(nTime)
    ! Compute sum of squre of error and deviation from menan (for obs) 
    start_ind = start_cal
    end_ind = start_cal + 29
    do itime = 1,nTime
      month_sim = sum(sim(ibasin+1,start_ind:end_ind))
      month_obs = sum(obs(offset+start_ind:offset+end_ind))
      sumSqrErr = sumSqrErr + ((month_sim-month_obs)**2)
      sumSqrDev = sumSqrDev + ((month_obs-meanQ)**2)
      !update starting and ending indice for next month step
      start_ind = end_ind+1
      end_ind = end_ind + 29
    enddo
    !grab remainder portion and weight it by number of days
    month_sim = sum(sim(ibasin+1,end_ind+1:end_cal-1))
    month_obs = sum(obs(offset+end_ind+1:end_cal-1))
    sumSqrErr = sumSqrErr + ((month_sim-month_obs)**2) * real((end_cal-1-(offset+end_ind+1))/30.0)
    sumSqrDev = sumSqrDev + ((month_obs-meanQ)**2) * real((end_cal-1-(offset+end_ind+1))/30.0)
    ! Compute nse for current basin 
    basin_nse(ibasin+1) = sumSqrErr/sumSqrDev
  enddo
  select case( agg )
  case(1); objfn = sum(basin_nse*obj_fun_weight)
  case(2); objfn = (sum((basin_nse*obj_fun_weight)**6.0_dp))**(1.0_dp/6.0_dp)
  end select
  return
end subroutine

!***********************************************************************
! calculate daily Kling-Gupta Efficiency (KGE)
!***********************************************************************
subroutine calc_kge_region( sim, obs, agg, objfn)
  implicit none
!input variables 
  real(dp), dimension(:,:), intent(in)  :: sim 
  real(dp), dimension(:),   intent(in)  :: obs 
  integer(i4b),             intent(in)  :: agg          ! basin aggregation method
!output variables
  real(dp),                 intent(out) :: objfn 
!local variables
  integer(i4b)                          :: ibasin       ! loop index
  integer(i4b),dimension(nbasin)        :: basin_id
  real(dp)                              :: Smax=0.6_dp        ! upper threshold for score function 
  real(dp)                              :: Smin=0.3_dp        ! lower threshold for score function 
  real(dp),    dimension(nbasin)        :: basin_score        ! score function  
  real(dp),    dimension(nbasin)        :: obj_fun_weight
  real(dp),    dimension(nbasin)        :: basin_kge
  real(dp)                              :: cc,alpha,betha,mu_s,mu_o,sigma_s,sigma_o
  integer(i4b)                          :: offset

  open (UNIT=58,file=trim(basin_objfun_weight_file),form='formatted',status='old')
  read (UNIT=58,fmt=*) ( basin_id(ibasin),obj_fun_weight(ibasin), ibasin=1,nbasin)
  close(UNIT=58)
  do ibasin = 0,nbasin-1
    !offset places me at the start of each basin
    offset = ibasin*sim_len
    !! mean
    mu_s=sum(sim(ibasin+1,start_cal:end_cal))/real((end_cal-start_cal)+1)
    mu_o=sum(obs(offset+start_cal:offset+end_cal))/real((end_cal-start_cal)+1)
    !compute the standard deviation
    sigma_s = sqrt (sum( (sim(ibasin+1,start_cal:end_cal)-mu_s)**2 )/real((end_cal-start_cal)+1))
    sigma_o = sqrt (sum( (obs(offset+start_cal:offset+end_cal)-mu_o)**2 )/real((end_cal-start_cal)+1))
    !compute correlation 
    call pearsn(sim(ibasin+1,start_cal:end_cal), obs(offset+start_cal:offset+end_cal), cc)
    betha = mu_s/mu_o
    alpha = sigma_s/sigma_o
    basin_kge(ibasin+1) =( sqrt((cc-1.0)**2.0_dp + (alpha-1.0)**2.0_dp + (betha-1.0)**2.0_dp) )
  enddo
  write(*,"(10f9.5)") ( basin_kge(ibasin), ibasin=1,nbasin)
  select case( agg )
  case(1); objfn = sum(basin_kge*obj_fun_weight)
  case(2); objfn = (sum((basin_kge*obj_fun_weight)**6.0_dp))**(1.0_dp/6.0_dp)
  case(3); 
    where(basin_kge<=Smin) basin_score=1.0_dp
    where(basin_kge>Smax)  basin_score=0.0_dp
    where(basin_kge>Smin .and. basin_kge<=Smax) basin_score=(Smax-basin_kge)/(Smax-Smin)
    objfn=sum(basin_score)
  end select
  return
end subroutine

!***********************************************************************
! calculate daily log(KGE)+KGE
!***********************************************************************
subroutine calc_log_kge_region( sim, obs, agg, objfn)
  implicit none
!input variables 
  real(dp), dimension(:,:), intent(in)       :: sim 
  real(dp), dimension(:),   intent(in)       :: obs 
  integer(i4b),             intent(in)       :: agg          ! basin aggregation method
!output variables
  real(dp),                 intent(out)      :: objfn 
!local variables
  integer(i4b)                               :: ibasin       ! loop index
  integer(i4b)                               :: offset
  integer(i4b),            dimension(nbasin) :: basin_id
  real(dp)                                   :: Smax=0.6_dp        ! upper threshold for score function 
  real(dp)                                   :: Smin=0.3_dp        ! lower threshold for score function 
  real(dp),    allocatable,dimension(:,:)    :: simIn,logSimIn
  real(dp),    allocatable,dimension(:)      :: obsIn,logObsIn
  real(dp),                dimension(nbasin) :: obj_fun_weight
  real(dp),                dimension(nbasin) :: basin_objfn
  real(dp),                dimension(nbasin) :: basin_score        ! score function  
  real(dp)                                   :: cc,alpha,betha,mu_s,mu_o,sigma_s,sigma_o
  real(dp)                                   :: log_cc,log_alpha,log_betha,log_mu_s,log_mu_o,log_sigma_s,log_sigma_o

  allocate(simIn(nbasin,sim_len))
  allocate(obsIn(nbasin*sim_len))
  allocate(logSimIn(nbasin,sim_len))
  allocate(logObsIn(nbasin*sim_len))
  open (UNIT=58,file=trim(basin_objfun_weight_file),form='formatted',status='old')
  read (UNIT=58,fmt=*) ( basin_id(ibasin),obj_fun_weight(ibasin), ibasin=1,nbasin)
  close(UNIT=58)
  obsIn = obs 
  simIn = sim
  where(obsIn<verySmall) obsIn=verySmall
  where(simIn<verySmall) simIn=verySmall
  logObsIn = log(obsIn)
  logSimIn = log(simIn)
  do ibasin = 0,nbasin-1
    !offset places me at the start of each basin
    offset = ibasin*sim_len
    !! mean
    mu_s    = sum(simIn(ibasin+1,start_cal:end_cal))/real((end_cal-start_cal)+1)
    mu_o    = sum(obsIn(offset+start_cal:offset+end_cal))/real((end_cal-start_cal)+1)
    log_mu_s= sum(logSimIn(ibasin+1,start_cal:end_cal))/real((end_cal-start_cal)+1)
    log_mu_o= sum(logObsIn(offset+start_cal:offset+end_cal))/real((end_cal-start_cal)+1)
    !compute the standard deviation
    sigma_s     = sqrt (sum( (simIn(ibasin+1,start_cal:end_cal)-mu_s)**2 )/real((end_cal-start_cal)+1))
    sigma_o     = sqrt (sum( (obsIn(offset+start_cal:offset+end_cal)-mu_o)**2 )/real((end_cal-start_cal)+1))
    log_sigma_s = sqrt (sum( (logSimIn(ibasin+1,start_cal:end_cal)-log_mu_s)**2 )/real((end_cal-start_cal)+1))
    log_sigma_o = sqrt (sum( (logObsIn(offset+start_cal:offset+end_cal)-log_mu_o)**2 )/real((end_cal-start_cal)+1))
    !compute correlation 
    call pearsn(simIn(ibasin+1,start_cal:end_cal), obsIn(offset+start_cal:offset+end_cal), cc)
    call pearsn(logSimIn(ibasin+1,start_cal:end_cal), logObsIn(offset+start_cal:offset+end_cal), log_cc)
    betha = mu_s/mu_o
    alpha = sigma_s/sigma_o
    log_betha = log_mu_s/log_mu_o      
    log_alpha = log_sigma_s/log_sigma_o
    basin_objfn(ibasin+1) = ( sqrt((cc-1.0)**2.0_dp + (alpha-1.0)**2.0_dp + (betha-1.0)**2.0_dp) )
    basin_objfn(ibasin+1) = basin_objfn(ibasin+1)+( sqrt((log_cc-1.0)**2.0_dp + (log_alpha-1.0)**2.0_dp + (log_betha-1.0)**2.0_dp) )
    basin_objfn(ibasin+1) =basin_objfn(ibasin+1)/2.0_dp
  enddo
  select case( agg )
  case(1); objfn = sum(basin_objfn*obj_fun_weight)
  case(2); objfn = (sum((basin_objfn*obj_fun_weight)**6.0_dp))**(1.0_dp/6.0_dp)
  case(3); 
    where(basin_objfn<=Smin) basin_score=1.0_dp
    where(basin_objfn>Smax)  basin_score=0.0_dp
    where(basin_objfn>Smin .and. basin_objfn<=Smax) basin_score=(Smax-basin_objfn)/(Smax-Smin)
    objfn=sum(basin_score)
  end select
  return
end subroutine


subroutine pearsn(x,y,r)
  implicit none
  !input variables
  real(dp), dimension(:), intent(in)  :: x
  real(dp), dimension(:), intent(in)  :: y
  !output variables
  real(dp),               intent(out) :: r
  !local variables
  real(dp), dimension(size(x))        :: xt,yt
  real(dp)                            :: ax,ay,sxx,sxy,syy
  integer(i4b)                        :: n

  n=size(x)
  ax=sum(x)/n
  ay=sum(y)/n
  xt(:)=x(:)-ax
  yt(:)=y(:)-ay
  sxx=dot_product(xt,xt)
  syy=dot_product(yt,yt)
  sxy=dot_product(xt,yt)
  r=sxy/(sqrt(sxx*syy)+verySmall)
  return
end subroutine

!******************************
! compute percent bias of hydrologic signatures
!******************************
subroutine calc_sigBias_region(sim, obs, agg, objfn) 
  ! aggregated absolute percentage signature bias
  ! Refer to paper below
  ! Yilmaz, K. K., H. V. Gupta, and T. Wagener (2008), 
  ! A process-based diagnostic approach to model evaluation: Application to the NWS distributed hydrologic model, 
  ! Water Resour. Res., 44, W09417, doi:10.1029/2007WR006716.
  implicit none
  !input variables 
  real(dp),                intent(in)     :: sim(:,:)
  real(dp),                intent(in)     :: obs(:) 
  integer(i4b),            intent(in)     :: agg          ! basin aggregation method
  !output variables
  real(dp),                intent(out)    :: objfn 
  ! local variables
  integer(i4b)                            :: ibasin,iTime ! loop index
  integer(i4b)                            :: i30,i50,i80
  integer(i4b)                            :: idx(1)
  integer(i4b)                            :: nTime            
  integer(i4b)                            :: offset
  real(dp)                                :: pBias
  real(dp)                                :: pBiasFHV
  real(dp)                                :: pBiasFLV
  real(dp)                                :: pBiasFMS
  real(dp)                                :: pBiasFMM
  real(dp)                                :: cc              ! correlation
  real(dp),    allocatable                :: p(:)            ! probability
  real(dp),    allocatable,dimension(:,:) :: simIn
  real(dp),    allocatable,dimension(:)   :: obsIn
  real(dp),    allocatable                :: simBasin(:)
  real(dp),    allocatable                :: obsBasin(:)
  integer(i4b),dimension(nbasin)          :: basin_id
  real(dp),    dimension(nbasin)          :: obj_fun_weight
  real(dp),    dimension(nbasin)          :: basin_sigBias
  
  allocate(simIn,source=sim)
  allocate(obsIn,source=obs)
  where(obsIn<verySmall) obsIn=verySmall
  where(simIn<verySmall) simIn=verySmall
  open (UNIT=58,file=trim(basin_objfun_weight_file),form='formatted',status='old')
  read (UNIT=58,fmt=*) ( basin_id(ibasin),obj_fun_weight(ibasin), ibasin=1,nbasin)
  close(UNIT=58)
  nTime=end_cal-start_cal+1
  allocate(p(nTime))
  allocate(simBasin(nTime))
  allocate(obsBasin(nTime))
  p=(/ (real(itime)/(real(nTime)+1.0_dp), iTime=1,nTime) /)
  idx=minloc(abs(p-0.3_dp))
  i30=idx(1)
  idx=minloc(abs(p-0.8_dp))
  i80=idx(1)
  idx=minloc(abs(p-0.5_dp))
  i50=idx(1)
  do ibasin = 0,nbasin-1
    offset = ibasin*sim_len
    simBasin=simIn(ibasin+1,start_cal:end_cal)
    obsBasin=obsIn(offset+start_cal:offset+end_cal)
    call sort(simBasin)
    call sort(obsBasin)
    ! compute signature
    pBias=sum( simIn(ibasin+1,start_cal:end_cal)-obsIn(offset+start_cal:offset+end_cal) )/sum(obsBasin)
    pBiasFMS=(( log(simBasin(i80))-log(simBasin(i30)) )-(log(obsBasin(i80))-log(obsBasin(i30))))/( log(obsBasin(i80))-log(obsBasin(i30)) )
    pBiasFHV=sum(simBasin(i80:nTime)-obsBasin(i80:nTime))/sum(obsBasin(i80:nTime))
    pBiasFLV=(sum(log(simBasin(1:i30))-log(simBasin(1)) )-sum(log(obsBasin(1:i30))-log(obsBasin(1))+verySmall))/sum( log(obsBasin(1:i30))-log(obsBasin(1))+verySmall )
    pBiasFMM= (log(simBasin(i50))-log(obsBasin(i50))) /( log(obsBasin(i50)) )
    call pearsn(simIn(ibasin+1,start_cal:end_cal),obsIn(offset+start_cal:offset+end_cal), cc)
    basin_sigBias(iBasin+1) = ( (1.0_dp-cc)+abs(pBias)+abs(pBiasFHV)+abs(pBiasFLV)+abs(pBiasFMS)+abs(pBiasFMM) )/6.0_dp
  enddo
  print*,'Signature-Objectiver-function components'
  print*,'pBias=',pBias
  print*,'pBiasFMS=',pBiasFMS
  print*,'pBiasFHV=',pBiasFHV
  print*,'pBiasFLV=',pBiasFLV
  print*,'pBiasFMM=',pBiasFMM
  print*,'correlation=',cc
  select case( agg )
  case(1); objfn = sum(basin_sigBias*obj_fun_weight)
  case(2); objfn = (sum((basin_sigBias*obj_fun_weight)**6.0_dp))**(1.0_dp/6.0_dp)
  end select
  return
end subroutine

function scoref(sigBias, Dstar, Dmax)
  ! sigBias is percent bias, 
  ! if sigBias is less than Dstar, get score one.
  ! if sigBias is greater than Dmax, get zero score,
  ! Dstar< sigBias < Dmax, get fractinal score between 0 and 1
  ! Shafii and Tolson 2015, WRR
  implicit none
  real(dp) ,intent(in) :: sigBias
  real(dp) ,intent(in) :: Dstar
  real(dp) ,intent(in) :: Dmax
  real(dp)             :: scoref
  
  if ( abs(sigBias) < abs(Dstar) ) then
    scoref=1.0_dp
  elseif ( abs(sigBias) > abs(Dmax) ) then
    scoref=0.0_dp
  else 
    scoref=( abs(Dmax)-abs(sigBias) )/( abs(Dmax)-abs(Dstar) )
  endif
  return
end function

subroutine sort(vec)
  implicit none
  real(dp) ,intent(inout) :: vec(:)
  real(dp)                :: buf
  integer(i4b)            :: nsize, i
  integer(i4b)            :: k(1)

  nsize = size(vec)
  do i = 1, nsize
    k   = minloc(vec(i:nsize))+i-1
    buf = vec(i)
    vec(i) = vec(k(1))
    vec(k(1)) = buf
  enddo
  return
end subroutine

!***********************************
! Output sim and obs in separate file 
!******************************
subroutine out_opt_sim(sim, obs)
  use strings
  implicit none
  !input variables 
  real(dp), dimension(:,:), intent(in)  :: sim 
  real(dp), dimension(:), intent(in)    :: obs 
  !local variables
  integer(i4b)                          :: itime,ibasin
  integer(i4b)                          :: offset
  character(len=1000),dimension(10)     :: tokens
  character(len=1000)                   :: last_token
  integer(i4b)                          :: nargs
  character(len=2000)                   :: out_name
  character(len=1)                      :: delims

  delims='/'
  call parse(obs_name,delims,tokens,nargs)
  last_token = tokens(nargs)
  out_name = trim(sim_dir)//last_token(1:9)//"_flow.txt"
  open(unit=88,file=out_name)
  do ibasin = 0,nbasin-1
    offset = ibasin*sim_len
    do itime = start_cal,end_cal-1
      write(unit=88,fmt=*) sim(ibasin+1,itime),obs(itime+offset)
    enddo
  enddo
  close(unit=88)
  return
end subroutine

!******************************
! Read observed streamflow
!******************************
subroutine read_obs(obs, err, message)
  use ascii_util, only:file_open
  implicit none
  !output variables
  real(dp), dimension(:),  intent(out)   :: obs
  integer(i4b),            intent(out)   :: err      ! error code
  character(*),            intent(out)   :: message  ! error message
  !local variables
  character(len=256)                     :: cmessage ! error message from downward subroutine
  integer(i4b)                           :: unt      ! DK: need to either define units globally, or use getSpareUnit
  integer(i4b)                           :: itime    ! loop index

  ! initialize error control
  err=0; message='read_obs/'
  !read observed streamflow
  call file_open(trim(obs_name), unt, err, cmessage)
  if(err/=0)then; message=trim(message)//trim(cmessage); return; endif
  do itime = 1,sim_len*nbasin
    read (unt,fmt=*) obs(itime)
  enddo
  close(unt)
  return
end subroutine

!******************************
! Aggregate hru value to basin
!******************************
subroutine agg_hru_to_basin(simHru,simBasin,err,message)
  use ascii_util, only:file_open
  implicit none
  !input variables
  real(dp),dimension(:,:),intent(in)    :: simHru
  !output variables
  real(dp),dimension(:,:),intent(out)   :: simBasin
  integer(i4b),           intent(out)   :: err                     ! error code
  character(*),           intent(out)   :: message                 ! error message
  !local variables
  character(len=strLen)                 :: cmessage                ! error message from downward routine
  integer(i4b)                          :: unt                     ! DK: need to either define units globally, or use getSpareUnit
  real(dp)                              :: basin_area
  integer(i4b)                          :: ibasin,icell       ! loop index
  integer(i4b)                          :: ncell
  integer(i4b)                          :: dum,c_cell

  ! initialize error control
  err=0; message='agg_hru_to_basin/'
  !set output variable to zero
  simBasin = 0.0
  !cell counter
  c_cell = 1
  !open a few files
  call file_open(trim(region_info),unt, err, cmessage)
  if(err/=0)then; message=trim(message)//trim(cmessage); return; endif
  do ibasin = 1,nbasin
    read (unt,fmt=*) dum, dum, basin_area, ncell
    do icell = 1,ncell
      simBasin(ibasin,:) = simBasin(ibasin,:) + simHru(c_cell,:)
      c_cell = c_cell + 1
    enddo !end of cell  
  enddo !end basin loop
  close(unt)
  return
end subroutine

!******************************
! routing runoff 
!******************************
subroutine route_q(qin,qroute,ushape,uscale, err, message)
  implicit none
  !input variables
  real(dp),dimension(:,:), intent(in)    :: qin
  real(dp),intent(in)                    :: ushape,uscale
  !output variables
  real(dp),dimension(:,:), intent(out)   :: qroute
  integer(i4b),            intent(out)   :: err          ! error code
  character(*),            intent(out)   :: message      ! error message
  !local variables
  integer(i4b)                           :: iEle         ! loop index of spatial elements
  integer(i4b)                           :: nEle         ! number of spatial elements (e.g., hru, basin)

  ! initialize error control
  err=0; message='route_q/'
  nEle=size(qin,1) 
  ! route flow for each basin in the region now
  if (ushape .le. 0.0 .and. uscale .le. 0.0) then 
    qroute=qin
  else
    do iEle=1,nEle
      call duamel(qin(iEle,1:sim_len), ushape, uscale, 1.0_dp, sim_len, qroute(iEle,1:sim_len), 0)
    enddo
  end if
end subroutine route_q

!************************************
! unit hydrograph construction and convolution routine
!************************************
  subroutine duamel(Q,un1,ut,dt,nq,QB,ntau,inUH)
    implicit none
    ! input 
    real(dp),   dimension(:),          intent(in)  :: Q      ! instantaneous flow
    real(dp),                          intent(in)  :: un1    ! scale parameter
    real(dp),                          intent(in)  :: ut     ! time parameter
    real(dp),                          intent(in)  :: dt     ! time step 
    integer(i4b),                      intent(in)  :: nq     ! size of instantaneous flow series
    integer(i4b),                      intent(in)  :: ntau 
    real(dp),   dimension(:),optional, intent(in)  :: inUH   ! optional input unit hydrograph  
    ! output
    real(dp),dimension(:),             intent(out) :: QB     ! Routed flow
    ! local 
    real(dp),dimension(1000)                       :: uh     ! unit hydrograph (use 1000 time step)
    integer(i4b)                                   :: m      ! size of unit hydrograph
    integer(i4b)                                   :: A,B
    integer(i4b)                                   :: i,j,ij ! loop index 
    integer(i4b)                                   :: ioc    ! total number of time step  
    real(dp)                                       :: top
    real(dp)                                       :: toc
    real(dp)                                       :: tor
    real(dp)                                       :: spv    ! cumulative uh distribution to normalize it to get unit hydrograph
    
    !size of unit hydrograph 
    m=size(uh)
    !initialize unit hydrograph 
    uh=0._dp
    ! Generate unit hydrograph
    if (un1 .lt. 0) then ! if un1 < 0, routed flow = instantaneous flow 
      uh(1)=1.0_dp
      m = 1
    else
      if (present(inUH)) then  !update uh and size of uh
        uh=inUH
        m=size(uh)  
      else 
        spv=0.0_dp
        toc=gf(un1)
        toc=log(toc*ut)
        do i=1,m
          top=i*dt/ut
          tor=(UN1-1)*log(top)-top-toc
          uh(i)=0.0_dp
          if(tor.GT.-8.0_dp) then 
            uh(i)=exp(tor)
          else 
            if (i .GT. 1) then 
              uh(i) = 0.0_dp
            end if 
          end if 
          spv=spv+uh(i) ! accumulate uh each uh time step
        end do
        if (spv .EQ. 0) spv=1.0E-5
        spv=1.0_dp/spv  
        do i=1,m
          uh(I)=uh(i)*spv  ! normalize uh so cumulative uh = 1
        end do
      endif
    endif
    ! do unit hydrograph convolution
    IOC=nq+ntau
    if (nq.LE.m) then
      do i=1,IOC
        QB(i)=0.0_dp
        A=1
        if(i.GT.m) A=I-m+1
        B=I
        if(i.GT.nq) B=nq
        do j=A,B
          ij=i-j+1
          QB(i)=QB(i)+Q(J)*uh(ij)
        end do
      end do
    else
      do i=1,IOC
        QB(i)=0.0_dp
        A=1
        if(i.GT.nq) A=i-nq+1
        B=i
        if(i.GT.M) B=M 
        do j=A,B
          ij=i-j+1
          QB(i)=QB(i)+uh(J)*Q(ij)
        end do
      end do 
    end if
    return 
  end subroutine
  
  !=================================================================
  function gf(Y)
    implicit none
    !input 
    real(dp),intent(in)  :: y
    !local
    real(dp)             :: gf 
    real(dp)             :: x
    real(dp)             :: h
  
    H=1_dp
    x=y
    do 
      if(x.le.0_dp) exit
      if(x.lt.2_dp .and. x.gt.2_dp) then
        gf=H
        exit
      end if
      if(x.gt.2_dp) then
        if(x.le.3_dp) then
          x=x-2_dp
          h=(((((((.0016063118_dp*x+0.0051589951_dp)*x+0.0044511400_dp)*x+.0721101567_dp)*x  &
            +.0821117404_dp)*x+.4117741955_dp)*x+.4227874605_dp)*x+.9999999758_dp)*h
          gf=H 
          exit
        else
          x=x-1_dp
          H=H*x
          cycle
        end if
      else
        H=H/x
        x=x+1_dp
        cycle
      end if
    end do
    return
  end function

end module eval_model 

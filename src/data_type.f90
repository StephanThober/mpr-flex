module data_type

! Here define custum data type    

  use nrtype

  implicit none

  save

! ***********************************************************************************************************
! Define data structure of model parameter metadata
! ***********************************************************************************************************
type,public  :: par_meta
  character(len=64)   :: pname=''      ! parameter name
  real(dp)            :: val=-999.0_dp ! default bound 
  real(dp)            :: lwr=-999.0_dp ! lower and upper bounds
  real(dp)            :: upr=-999.0_dp ! lower and upper bounds
  logical(lgt)        :: flag=.False.  ! flag to write variable to the output file
endtype par_meta

type,extends(par_meta), public  :: cpar_meta
  integer(i4b)        :: ixMaster=-999
endtype cpar_meta

end module data_type

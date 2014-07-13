
*miscellany especially actual data and runs;

*There WILL be a preprocess for data, things like built in missing (e.g. GEF) as I move to assn of full data and make my own missing logic;
/*exampleS:
%let ForecastSeries = lz1;
libname g 'C:\Users\anhutz\Desktop\msa\TimeSeries\PROJECTS\GEFCom2012\data';
proc expand data=g.gef out=gexpand; convert &ForecastSeries.; run; quit; 
data gexpand;
set gexpand(where=(&ForecastSeries.^=.));* to have nontriv (bc GEF has miss at end to forecast, Tao held true holdout) ;
run;


data comed;
infile "C:\Users\anhutz\Desktop\msa\msa_backup_NO Video\TS--16Sep2012\PROJECT\phase2\phase1.csv" dsd stopover firstobs=2;
format date date9.;
input date :mmddyy. hour load temp;

   *datetime "key";
format datetime datetime.;
datetime=dhms(date,hour,0,0);
if (mday=31 and month=12 and 20<=hour<=24) or (mday=1 and month=1 and 1<=hour<=9 ) then new_year=1; else new_year=0;
if (mday=31 and month=10 and 20<=hour<=24) or (mday=1 and month=11 and 1<=hour<=9 ) then halloween=1; else halloween=0;
if (mday=25 and month=12) then christmas=1; else christmas=0;
if (mday=24 and month=12) then xmaseve=1; else xmaseve=0;
if (month=11 and weekday=5 and 21<mday<29) then thanks=1; else thanks=0;*4th Thursday of Nov?;
if (month=11 and weekday=6 and 22<mday<30) then blackfri=1; else blackfri=0;
if (month=7 and mday=4) then july4=1; else july4=0;
MONTHofYear=month(date);
DAYofWeek=weekday(date);
HOURofDay=hour;
role="train";
trend+1;
run;

*/



*---------------------------*




*pomans datetime processing;
data dtconv;
start="30JUN08:07:00:00"dt;
end="02Jul08:07:00:00"dt;
call symputx('fcststart',start,'g');
call symputx('fcstend',end,'g');
run;
/*
							ForecastStartDatetime  =&fcststart,
							ForecastEndDatetime    =&fcstend,
*/
proc mi data=g.gef(where=(ts1^=.))  nimpute=0;
  em out=gef_MI;
  var lz1 lz2 avgtemp temprange monthofyear hourofday yearofdecade trend;
run;
proc sgplot data=work.gef_mi; 
*where '01jul2005:00:00'dt<datetime<'01jul2006:00:00'dt;
where '01dec2005:00:00'dt<datetime<'01jan2006:00:00'dt;
series x=datetime y=lz1;
series x=datetime y=lz3 / y2axis;
run;
proc print data=gef_mi; where lz1<=0; run;

/* data gef_MI; set gef_mi; where trend<39025; run; */
%module1_build(             InputDataset           =work.gef_MI, 
							ForecastSeries         =lz2,
							DateVariable           =datetime,
							PredictedTemperature   =ts6
						);

%module1_build(             InputDataset           =work.comed, 
							ForecastSeries         =load,
							DateVariable           =datetime,
							PredictedTemperature   =temp,
							RoleVariable           =role);



/****************************************************        Examples        ****************************************************/
/*****************************************************************************************************************************************/
/*****************************************************************************************************************************************/
%let ForecastSeries = lz1;
libname g 'C:\Users\anhutz\Desktop\msa\TimeSeries\PROJECTS\GEFCom2012\data';
proc expand data=g.gef out=gexpand; convert &ForecastSeries.; run; quit; 

data gexpand;
set gexpand(where=(&ForecastSeries.^=.));* to have nontriv (bc GEF has miss at end to forecast, Tao held true holdout) ;
run;
proc mi data=g.gef(where=(ts1^=.))  nimpute=0;
  em out=gef_MI;
  var lz1 lz2 avgtemp temprange monthofyear hourofday yearofdecade trend;
run;
proc sgplot data=work.gef_mi; 
*where '01jul2005:00:00'dt<datetime<'01jul2006:00:00'dt;
where '01dec2005:00:00'dt<datetime<'01jan2006:00:00'dt;
series x=datetime y=lz1;
series x=datetime y=lz3 / y2axis;
run;
proc print data=gef_mi; where lz1<=0; run;

%module3_arch(iter=2,InputDataset=work.gef_MI);
/* data gef_MI; set gef_mi; where trend<39025; run; */
%module1_build(             InputDataset           =work.gef_MI, 
							ForecastSeries         =lz2,
							DateVariable           =datetime,
							PredictedTemperature   =ts6,
							ForecastArchitecture           =architect);
						);
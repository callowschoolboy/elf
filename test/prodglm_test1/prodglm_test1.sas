
/************************************************************************************************************************************************************************
* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * 
*
*
*                  Hutzel Forecasting Code Library
*
*       NAME: ProdGLM_test1.sas
* Author:     Andrew J. Hutzel
* Subject:    First unit test of Step-ahead-holdout Production GLM 
* Byline:     DynReg 3-days test 
* Sections:   
*
*  REFERENCE: Forecasting System as of 05Jul2014 (arch ds for dynamic holdout)
*   COMMENTS: Benched inputs, compare to those first.  Then bench DAT file (tab delimited) of the 3 iterations outputs.         
*                                    
*    PURPOSE: To be run any time sanity needs to be checked, i.e. often.
*  
*      NOTES: System known to be stable, this test runs in ~1 min.
*             Plan to expand to collate and compare to intermediate results,
*              but currently only one final output ds is tested against, working_holdact.
*
*
* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * 
*************************************************************************************************************************************************************************/




/******************************     ******************************/
/******************************     ******************************/
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
%module3_arch(iter=3,InputDataset=work.comed);

libname benches 'C:\Users\anhutz\Desktop\msa\msa_backup_NO Video\TS--16Sep2012\PROJECT\2013\test\prodglm_test1';
proc compare data=benches.comed compare=comed criteria=1e-12 method=relative(1e-9); run;
%let catch_comed=&sysinfo;
%put catch_comed=&catch_comed;

proc compare data=benches.architect compare=architect; run;
%let catch_architect=&sysinfo;
%put catch_architect=&catch_architect;



%module1_build(             InputDataset           =work.comed, 
							ForecastSeries         =load,
							DateVariable           =datetime,
							PredictedTemperature   =temp,
							ForecastArchitecture           =architect);

*compare to working_holdact;
proc compare data=benches.working_holdact compare=working_holdact criteria=1e-8;
var predicted_load;
run;
%let catch_hold=&sysinfo;
%put catch_hold=&catch_hold;

data _null_;
if catch_comed>64 or catch_architect>64 or catch_hold>64 then do;
	put "At least one dataset does not match its bench.  FAILURE!";
end;
else put "Test PASSED.";
run;
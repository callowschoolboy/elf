title;
		*Next step is to move from COMED>GEF back to just COMED, hope MPAE in teh 1% area since no EXPAND.  Add a lag of load, data schema to accomodate weather.com temps 71.7;

%let DateVariable = datetime;
%let PredictedTemperature = ts2;
%let RoleVariable = role;

%let ForecastSeries = lz1;
libname g 'C:\Users\anhutz\Desktop\msa\TimeSeries\PROJECTS\GEFCom2012\data';
/*proc expand data=g.gef out=gexpand2; convert &ForecastSeries.; run; quit; */
proc mi data=g.gef(where=(ts1^=.))  nimpute=0;
  em out=gexpand;
  var lz1 lz2 avgtemp monthofyear hourofday;
run;


data gexpand;
set gexpand(where=(&ForecastSeries.^=.));*arbitrary to have nontriv (bc GEF has miss at end to forecast, Tao held true holdout)  PLAN TO REMOVE;
	T2_0=&PredictedTemperature.**2;
	T3_0=&PredictedTemperature.**3;
	T1_1=lag(&PredictedTemperature.);
	temp_diff=dif(&PredictedTemperature.);
	L_1=lag(&ForecastSeries.);
	
	T2_1=T1_1**2;
	T3_1=T1_1**3;
run;
*knock back 48 obs;
proc sql; 
select count(*) 
 into : inputnumobs 
 from gexpand; 
quit;
%let train1_limit_Nminus48=%eval(&inputnumobs-48);
%put train1_limit_Nminus48=&train1_limit_Nminus48;

*forking train/hold, train1 will become the main working dataset;
data train1 hold1; 
set gexpand; 
if _n_ <= &train1_limit_Nminus48 then output train1; 
else output hold1; 
run;

*There may be a preprocess for data, things like built in missing (e.g. GEF) when I operate off of assn of full data and make my own missing logic;


*CHECK FOR INFORMATION LEAKS 
1. when append should mean next iter gets predictions as inputs 
2.at beginning have to RECALC LAGS on the working copy so that pred-as-ins occurs (TU SEEMS TO HAVE DONE THIS)
can always rewrite this for contrived no-leak possible case then reintegrate that code.  But have checked, confident no info leaks here; 

%macro OneSteppingLoop(h=HOURofDay, d=DAYofWeek, m=MONTHofYear);

%do i= 1 %to 48 %by 1; 


	*Use a macro variable to point to the obsnum that is the next in line to be forecasted;
    **In a multilag GLM this is the start of the "ex ante gray period longjump"; 
	%let iteration_obs=%eval(&train1_limit_Nminus48 + &i); 
	%put iteration_obs=&iteration_obs;


	data hold2_single;
		set gexpand;
		if _n_=&iteration_obs then output;
	run;


	**IMPORTANT: we have to recalculate the lagged load (L_1) with the predicted value; 
	**For the first iteration of the loop, it is simply the ACTUAL value of the last obs, but for other iterations,
				  it is the FORECASTED value of the previous observation;
	DATA getastep_prediction;
		SET train1(IN=__ORIG) hold2_single;
		__FLAG=__ORIG; * you do need this to pass info downstream;
		*recalc lags or they will be stale i.e. info leaks;
		L_1=lag(&ForecastSeries.);
		*blank  out VoI for that last set ob;
		if not __FLAG then &ForecastSeries.=.;
	RUN;


	*model and output the predictions to the load.predicted data set (rough version); 
	PROC GLM DATA=getastep_prediction
			PLOTS=NONE NOPRINT /* heard NOPRINT can change answers, may move to ods close all ods select ~predict1_onestepiter */
		;
		CLASS &d. &h. &m.;
		MODEL &ForecastSeries. =
		/* Main Effects:  */ 
					trend 
					&m.
					L_1
					&PredictedTemperature. 
		/* 2-way Interactions: */
					&d.*&h.
				/* Temperature x hour */
					&PredictedTemperature.*&h.
					T2_0*&h. 
					T3_0*&h. 
					T1_1*&h. 
					T2_1*&h. 
					T3_1*&h. 
				/* Temperature x month */
					&PredictedTemperature.*&m.
					T2_0*&m. 
					T3_0*&m. 
					T1_1*&m. 
					T2_1*&m.	 
					T3_1*&m. 
				/* Load interactions: */
				    L_1*&h. 
					L_1*&m. 
		;
		RUN;

		OUTPUT OUT= predict1_onestepiter (WHERE=(NOT __FLAG))
			PREDICTED=predicted_Load ;
		RUN;
	QUIT;

	data predict1_onestepiter; * in place, shift that variable predicted_Load over to the target &ForecastSeries.;
	set predict1_onestepiter;
	&ForecastSeries. = predicted_Load;
	drop predicted_Load __FLAG;* __DEP;
	run; 

	*train1 is the working DS, append to there (closed loop) i.e. look there for predicteds theyll be obs > amper train1_limit_Nminus48; 
	%put APPENDINGggggggggggg; 
	proc append base=train1 data=predict1_onestepiter; run; quit;


%end;

data train3;
set train1;
if _n_ > &train1_limit_Nminus48 then output;
run;

*getting accuracy measures, namely RMSE, with SQL;
proc sql;
               create table working_holdact as
			    select actual.*, forec.&ForecastSeries. as predicted_Load label="Predicted Forecasts of &ForecastSeries."
				  from hold1 as actual, train3 as forec
				   where actual.&DateVariable.=forec.&DateVariable.  
		;
  select sqrt(avg(se)) as rmse, sqrt(avg(sa)) as rmsa, avg(abs(&ForecastSeries.-predicted_Load)/&ForecastSeries.) as mape, (calculated rmse)/(calculated rmsa) as prmse_a
   from 
	  (  select *, (&ForecastSeries.-predicted_Load)**2 as se, (&ForecastSeries.)**2 as sa
		  from working_holdact
	   )
  ;
quit;

*  GRAPHS ;
*all hist+forec;
title "Forecast Horizon, Actuals v. Forecasts, Also temperature.";
proc sgplot data=working_holdact;
series x=&DateVariable. y=&ForecastSeries.       / lineattrs=(thickness=1);
series x=&DateVariable. y=predicted_Load         / lineattrs=(thickness=1);
series x=&DateVariable. y=&PredictedTemperature. / lineattrs=(thickness=1 color=yellow) y2axis;
run; quit;

/*forec, actual and temp for forehorz;
title "All historical obs and future, Also temperature.";
proc sgplot data=train1;
series x=&DateVariable. y=&ForecastSeries. ;* not working cause "test" erased from train1 and GEF includes the level "back" / group=role;
*series x=&DateVariable. y=&PredictedTemperature. /  lineattrs=(thickness=1 color=yellow) y2axis;
run; quit;
*/


%mend OneSteppingLoop;
options mprint mlogic nosymbolgen;
%OneSteppingLoop;


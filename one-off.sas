*COMED just with GEF data lz1 ts1;

%let ForecastSeries = lz1;
%let DateVariable = datetime;
%let PredictedTemperature = ts4;
%let RoleVariable = role;

libname g 'C:\Users\anhutz\Desktop\msa\TimeSeries\PROJECTS\GEFCom2012\data';
proc expand data=g.gef out=gexpand; convert &ForecastSeries.; run; quit; 


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

*There may be a preprocess for ;


*CHECK FOR INFORMATION LEAKS 
1. when append should mean next iter gets predictions as inputs 
2.at beginning have to RECALC LAGS on the working copy so that pred-as-ins occurs (TU SEEMS TO HAVE DONE THIS)
can always rewrite this for contrived no-leak possible case then reintegrate that code.  But have checked, confident no info leaks here; 

%macro OneSteppingLoop(h=HOURofDay, d=DAYofWeek, m=MONTHofYear);

%do i= 1 %to 48 %by 1; 


	*Substract  the total number of observations; 
	%let iteration_obs=%eval(&train1_limit_Nminus48 + &i); 
	%put iteration_obs=&iteration_obs;


	data hold2_single;
		set gexpand;
		if _n_=&iteration_obs then output;
	run;


	**IMPORTANT: we have to recalculate the lagged load (L_1) with the predicted value; **For the first iteration of the loop, it is simply the ACTUAL value of the last obs, but for other iterations,
				  it is the FORECASTED value of the previous observation;
	DATA getastep_prediction;
		SET train1(IN=__ORIG) hold2_single;
		__FLAG=__ORIG; * you do need this to pass info downstream;
		*recalc lags or they will be stale i.e. info leaks;
		L_1=lag(&ForecastSeries.);
				*blank it out;
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
	/*	Tus orig:   trend weekday*hour month
					temp*hour temp2*hour temp3*hour 
					month*temp month*temp2 month*temp3 
					temp_1*hour temp_1_2*hour temp_1_3*hour 
					temp_1*month temp_1_2*month	 temp_1_3*month 
					load_1 load_1*hour load_1*month 
					
					july4 new_year thanks christmas	  */
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

	*train1 is my working DS, append to there (closed loop) i.e. look there for predicteds theyll be obs > amper train1_limit_Nminus48; 
	%put APPENDINGggggggggggg; 
	proc append base=train1 data=predict1_onestepiter; run; quit;


%end;

data train3;
set train1;
if _n_ > &train1_limit_Nminus48 then output;
run;

	/*getting MAPE with my new COMPARE method did NOT seem to work since it doesn't seem to reflect RELATIVE percentages
	proc compare base=hold1 compare=train3 out=comparemethodmape method=relative(1000) outbase outcompare outdif outpercent;
	var &ForecastSeries.;
	run; */
*and getting RMSE with SQL;
proc sql;
  select sqrt(avg(se)) as rmse, sqrt(avg(sa)) as rmsa
   from 
	  (  select *, (&ForecastSeries.-predicted_Load)**2 as se, (&ForecastSeries.)**2 as sa
		  from 
			 (   select actual.*, forec.&ForecastSeries. as predicted_Load
				  from hold1 as actual, train3 as forec
				   where actual.&DateVariable.=forec.&DateVariable.  )
	   )
  ;
quit;


%mend OneSteppingLoop;
options mprint mlogic nosymbolgen;
%OneSteppingLoop;

